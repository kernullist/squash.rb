#!/usr/bin/ruby

require 'rubygems'
require 'bit-struct'
require 'zlib'
require 'time'

class SquashFS
	class LEBitStruct < BitStruct; default_options :endian => :little; end
	
	class Superblock < LEBitStruct
		Magic = 0x73717368
		
		unsigned	:magic,			32
		unsigned	:inodes,		32
		unsigned	:mkfs_time,		32
		unsigned	:block_size,	32
		unsigned	:fragments,		32
		unsigned	:compression,	16
		unsigned	:block_log,		16
		unsigned	:flags,			16
		unsigned	:no_ids,		16
		unsigned	:vers_maj,		16
		unsigned	:vers_min,		16
		unsigned	:root_inode,	64
		unsigned	:bytes_used,	64
		unsigned	:id_table_start,		64
		unsigned	:xattr_id_table_start,	64
		unsigned	:inode_table_start,		64
		unsigned	:directory_table_start,	64
		unsigned	:fragment_table_start,	64
		unsigned	:lookup_table_start,	64
	
		def compr_inode?; (flags & 1).zero?; end
		def compr_data?; (flags & 2).zero?; end
		def compr_frag?; (flags & 4).zero?; end
		def frag?; (flags & 8).zero?; end
		def always_frag?; (flags & 16) != 0; end
		def dups?; (flags & 32) != 0; end
		def export?; (flags & 64) != 0; end
		def comp_opt?; (flags & 1024) != 0; end
	end
	
	MetadataSize = 8192
	
	attr_reader :sb
	
	def read(off, size)
		@io.seek(off)
		@io.read(size)
	end
	
	def blocks_needed(size, block_size)
		q, r = size.divmod(block_size)
		q += 1 if r != 0
		return q
	end
	
	class Int64 < BitStruct::Vector
		unsigned :i, 64, :endian => :little
	end
	def unpack64(s)
		Int64.new(s).map { |x| x.i }
	end
	
	class MDPos
		attr_accessor :block, :offset, :length
		def initialize(b, o)
			@block, @offset, @length = b, o , 0
		end
		def self.inode(n, add = 0)
			new((n >> 16) + add, n & 0xffff)
		end
	end
	
		
	def read_id_table
		bytes = @sb.no_ids * 4
		nblocks = blocks_needed(bytes, MetadataSize)
		blocknos = unpack64(read(@sb.id_table_start, 8 * nblocks))
		@id_table = []
		blocknos.each { |b| @id_table.concat(read_block(b).unpack('V*')) }
	end
	def id(idx); @id_table[idx]; end
	
	def read_block(off)
		header = read(off, 2).unpack('v').first
		size = header & ~(1 << 15)
		compressed = (header - size).zero?
		
		data = @io.read(size)
		data = Zlib::Inflate.inflate(data) if compressed
		return data
	end
	
	def read_metadata(pos, size)
		ret = ""
		while size > 0
			data = read_block(pos.block)
			take = [data.size - pos.offset, size].min
			ret << data[pos.offset, take]
			
			size -= take
			pos.offset += take
			pos.length += take
			if pos.offset == data.size
				pos.block += data.size
				pos.offset = 0
			end
		end
		
		ret
	end
	def read_md_struct(pos, kl)
		kl.new(read_metadata(pos, kl.round_byte_length))
	end
	
	class Inode
		Types = [:dir, :reg, :sym, :blkd, :chrd, :fifo, :sock]
		
		class Base < LEBitStruct
			unsigned	:type,		16
			unsigned	:mode,		16
			unsigned	:uid,		16
			unsigned	:gid,		16
			unsigned	:mtime,		32
			unsigned	:inode_number,	32
		end
		class Dir < LEBitStruct
			unsigned	:start_block,	32
			unsigned	:nlink,			32
			unsigned	:file_size,		16
			unsigned	:offset,		16
			unsigned	:parent_inode,	32
		end
		TypeClasses = [Dir]
		
		def type_idx; @base.type % Types.size - 1; end
		def type; Types[type_idx]; end
		def time; Time.at(@base.mtime); end
		def uid; @fs.id(@base.uid); end
		def gid; @fs.id(@base.gid); end
		
		def modestr
			ret = "d-lbcps"[type_idx, 1]
			6.step(0, -3) do |sh|
				perm = (@base.mode >> sh) & 7
				"rwx".each_char do |c|
					ret << (perm & 4 > 0 ? c : '-')
					perm <<= 1
				end
				if @base.mode & (1 << 9 + sh/3) > 0
					c = sh > 0 ? 's' : 't'
					ret[-1,1] = ret[-1] == ?- ? c.upcase : c
				end
			end
			
			ret
		end
		
		def initialize(fs, iid)
			@fs = fs
			pos = MDPos.inode(iid, @fs.sb.inode_table_start)
			@base = @fs.read_md_struct(pos, Base)
			
			klass = TypeClasses[@base.type - 1] or raise 'Unsupported type'
			@type = @fs.read_md_struct(pos, klass)
		end
		
		def method_missing(meth, *args)
			[@type, @base].each do |b|
				return b.send(meth, *args) if b.respond_to?(meth)
			end
			super
		end
		
		def dump
			puts "inode %d: type %s, mode %s, uid %d, gid %d, time %s" %
				[@base.inode_number, type, modestr, uid, gid, time.iso8601]
		end
	end
	
	class Directory
		class Header < LEBitStruct
			unsigned	:count, 32
			unsigned	:start_block, 32
			unsigned	:inode_number, 32
		end
		class Entry < LEBitStruct
			unsigned	:offset, 16
			unsigned	:inode_number, 16
			unsigned	:type, 16
			unsigned	:size, 16
		end
		class Child
			attr_reader :entry, :name
			def initialize(fs, dirh, pos)
				@fs, @dirh = fs, dirh
				@entry = @fs.read_md_struct(pos, Entry)
				@name = @fs.read_metadata(pos, @entry.size + 1)
			end
			def inode_number; @entry.inode_number + @dirh.inode_number; end
		end
		
		attr_reader :entries
		def initialize(fs, inode)
			@fs = fs
			@entries = []
			
			# FIXME: loop
			pos = MDPos.new(inode.start_block + @fs.sb.directory_table_start,
				inode.offset)
			while pos.length + 3 < inode.file_size do
				dirh = @fs.read_md_struct(pos, Header)
				(dirh.count + 1).times do
					@entries << Child.new(@fs, dirh, pos)
					puts @entries[-1].name
				end
			end
		end
	end
	
	def initialize(path)
		@io = open(path)
		@sb = Superblock.new(@io)
		raise 'Not a squashfs filesystem' \
			unless @sb.magic == Superblock::Magic
		raise 'Unsupported version' \
			unless @sb.vers_maj == 4 && @sb.vers_min >= 0
		raise 'FIXME: Compression not zlib' unless @sb.compression == 1
		
		read_id_table
		@root = Inode.new(self, @sb.root_inode)
		
		@root.dump
		dir = Directory.new(self, @root)
	end
end

SquashFS.new(ARGV.shift)

# TODO
# directory reading
# data blocks / fragments
# all file types
# dir indexes
# xattrs
# lookup/export
# compression types
# metadata, block caches
