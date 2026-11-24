#!/usr/bin/env ruby

# Scores firmware regions by known DDC/CI VCP constants used as 8051
# compare/arithmetic immediates. This avoids treating capability strings and
# unrelated address operands as code references.

FEATURES = [
  0x04, 0x10, 0x12, 0x14, 0x16, 0x18, 0x1a,
  0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x60, 0x62,
  0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0, 0xd6,
  0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe7, 0xe8
].freeze

# CJNE A/@Ri/Rn,#imm,rel; XRL A,#imm; SUBB A,#imm; ADD A,#imm.
IMMEDIATE_OPCODES = ([0xb4, 0xb6, 0xb7] + (0xb8..0xbf).to_a + [0x64, 0x94, 0x24]).freeze
OPCODE_NAMES = {
  0xb4 => 'CJNE A', 0xb6 => 'CJNE @R0', 0xb7 => 'CJNE @R1',
  0x64 => 'XRL A', 0x94 => 'SUBB A', 0x24 => 'ADD A'
}.freeze

window_size = Integer(ENV.fetch('WINDOW', '1024'))
step = Integer(ENV.fetch('STEP', '128'))
minimum_score = Integer(ENV.fetch('MIN_SCORE', '5'))

ARGV.each do |path|
  data = File.binread(path).bytes
  matches = []

  (0...(data.length - 1)).each do |offset|
    opcode = data[offset]
    immediate = data[offset + 1]
    next unless IMMEDIATE_OPCODES.include?(opcode) && FEATURES.include?(immediate)

    matches << [offset, opcode, immediate]
  end

  regions = []
  (0...data.length).step(step) do |start|
    finish = [start + window_size, data.length].min
    region_matches = matches.select { |offset, _opcode, _immediate| offset >= start && offset < finish }
    features = region_matches.map { |_offset, _opcode, immediate| immediate }.uniq
    next if features.length < minimum_score

    regions << [features.length, start, finish, features, region_matches]
  end

  # Keep only local maxima so overlapping windows do not swamp the result.
  selected = regions.reject do |candidate|
    score, start, finish = candidate
    regions.any? do |other|
      other_score, other_start, other_finish = other
      other_score > score && other_start <= start && other_finish >= finish
    end
  end

  selected.sort_by { |score, start, _finish, _features, _matches| [-score, start] }.first(20).each do |score, start, finish, features, region_matches|
    puts format('%s 0x%04x..0x%04x score=%d features=%s',
                File.basename(path), start, finish - 1, score,
                features.sort.map { |value| format('%02x', value) }.join(','))
    region_matches.each do |offset, opcode, immediate|
      name = OPCODE_NAMES.fetch(opcode, opcode >= 0xb8 ? "CJNE R#{opcode - 0xb8}" : format('op %02x', opcode))
      puts format('  0x%04x  %-8s #%02x', offset, name, immediate)
    end
  end
end
