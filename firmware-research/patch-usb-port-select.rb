#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"

EXPECTED_SIZE = 18 * 65_536
EXPECTED_SHA256 = "7230e10cd846f99dd20ab0f8a3a29f0e50fcf551ce480f4adbed18d9a941ba35"

BANK = 2
DISPATCH_OFFSET = BANK * 65_536 + 0xE3A6
HANDLER_OFFSET = BANK * 65_536 + 0xFF00

# The Set-VCP jump table stores two target-address bytes followed by the VCP
# code.  EA is unadvertised and its original target, EF40, is a one-byte RET.
ORIGINAL_DISPATCH = [0xEF, 0x40, 0xEA].pack("C*")
PATCHED_DISPATCH = [0xFF, 0x00, 0xEA].pack("C*")

# 8051 implementation:
#
#   selected = (xram[CD3B] & 1) << 7
#   xram[CF03] = (xram[CF03] & 0x7F) | selected
#   xram[C9BB] = 1                  ; mark OSD user data dirty
#   lcall 30EC                      ; bank-16:DDB6, apply hub UFP switch
#   ret
#
# Value 0 is the Type-C upstream; value 1 is the USB-B upstream.
HANDLER = [
  0x90, 0xCD, 0x3B,
  0xE0,
  0x54, 0x01,
  0xC4,
  0x33, 0x33, 0x33,
  0x54, 0x80,
  0xFF,
  0x90, 0xCF, 0x03,
  0xE0,
  0x54, 0x7F,
  0x4F,
  0xF0,
  0x90, 0xC9, 0xBB,
  0x74, 0x01,
  0xF0,
  0x12, 0x30, 0xEC,
  0x22
].pack("C*")

def abort_with(message)
  warn "error: #{message}"
  exit 1
end

input_path, output_path = ARGV
abort_with("usage: #{$PROGRAM_NAME} ORIGINAL.bin PATCHED.bin") unless input_path && output_path

input_expanded = File.expand_path(input_path)
output_expanded = File.expand_path(output_path)
abort_with("input and output paths must differ") if input_expanded == output_expanded
abort_with("input file does not exist: #{input_path}") unless File.file?(input_path)
abort_with("output already exists: #{output_path}") if File.exist?(output_path)

firmware = File.binread(input_path)
abort_with("unexpected image size: #{firmware.bytesize}, expected #{EXPECTED_SIZE}") unless firmware.bytesize == EXPECTED_SIZE

input_sha256 = Digest::SHA256.hexdigest(firmware)
abort_with("unsupported firmware SHA-256: #{input_sha256}") unless input_sha256 == EXPECTED_SHA256

actual_dispatch = firmware.byteslice(DISPATCH_OFFSET, ORIGINAL_DISPATCH.bytesize)
abort_with("Set-VCP EA table entry does not match the expected original bytes") unless actual_dispatch == ORIGINAL_DISPATCH

original_cave = firmware.byteslice(HANDLER_OFFSET, HANDLER.bytesize)
abort_with("bank-2 FF00 code cave is not erased") unless original_cave == "\xFF".b * HANDLER.bytesize

patched = firmware.dup
patched[DISPATCH_OFFSET, 2] = PATCHED_DISPATCH.byteslice(0, 2)
patched[HANDLER_OFFSET, HANDLER.bytesize] = HANDLER

changed_offsets = []
firmware.bytes.each_with_index do |byte, index|
  changed_offsets << index if byte != patched.getbyte(index)
end

candidate_offsets = (DISPATCH_OFFSET...(DISPATCH_OFFSET + 2)).to_a +
                    (HANDLER_OFFSET...(HANDLER_OFFSET + HANDLER.bytesize)).to_a
allowed_offsets = candidate_offsets.select do |index|
  firmware.getbyte(index) != patched.getbyte(index)
end
abort_with("patch changed bytes outside the two expected ranges") unless changed_offsets == allowed_offsets
abort_with("patch unexpectedly changed image size") unless patched.bytesize == firmware.bytesize

FileUtils.mkdir_p(File.dirname(output_expanded))
File.binwrite(output_expanded, patched)

puts "input:  #{input_path}"
puts "        SHA-256 #{input_sha256}"
puts "output: #{output_path}"
puts "        SHA-256 #{Digest::SHA256.hexdigest(patched)}"
puts "changed bank 2: E3A6-E3A7 and FF00-FF#{format('%02X', HANDLER.bytesize - 1)}"
puts "VCP EA: 0 = USB-C upstream, 1 = USB-B upstream"
