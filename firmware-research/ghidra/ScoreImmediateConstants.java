// Scores discovered 8051 functions by selected immediate constants.
// @category AcerFirmware

import java.io.File;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.Memory;

public class ScoreImmediateConstants extends GhidraScript {
    private static final Set<Integer> IMMEDIATE_OPCODES = new HashSet<>();

    static {
        IMMEDIATE_OPCODES.add(0xb4); // CJNE A,#imm,rel
        IMMEDIATE_OPCODES.add(0xb6); // CJNE @R0,#imm,rel
        IMMEDIATE_OPCODES.add(0xb7); // CJNE @R1,#imm,rel
        for (int opcode = 0xb8; opcode <= 0xbf; opcode++) {
            IMMEDIATE_OPCODES.add(opcode); // CJNE Rn,#imm,rel
        }
        IMMEDIATE_OPCODES.add(0x64); // XRL A,#imm
        IMMEDIATE_OPCODES.add(0x94); // SUBB A,#imm
        IMMEDIATE_OPCODES.add(0x24); // ADD A,#imm
    }

    private static class Finding {
        final Function function;
        final Map<Integer, List<Address>> addresses;

        Finding(Function function, Map<Integer, List<Address>> addresses) {
            this.function = function;
            this.addresses = addresses;
        }
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 2) {
            throw new IllegalArgumentException("Expected output path and comma-separated hex constants");
        }

        Set<Integer> constants = new HashSet<>();
        for (String value : args[1].split(",")) {
            constants.add(Integer.parseInt(value.trim(), 16));
        }

        Memory memory = currentProgram.getMemory();
        List<Finding> findings = new ArrayList<>();
        FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
        for (Function function : functions) {
            Map<Integer, List<Address>> addresses = new HashMap<>();
            InstructionIterator instructions = currentProgram.getListing().getInstructions(function.getBody(), true);
            for (Instruction instruction : instructions) {
                Address address = instruction.getAddress();
                int opcode = memory.getByte(address) & 0xff;
                if (!IMMEDIATE_OPCODES.contains(opcode) || instruction.getLength() < 2) {
                    continue;
                }

                int immediate = memory.getByte(address.add(1)) & 0xff;
                if (!constants.contains(immediate)) {
                    continue;
                }
                addresses.computeIfAbsent(immediate, ignored -> new ArrayList<>()).add(address);
            }
            if (!addresses.isEmpty()) {
                findings.add(new Finding(function, addresses));
            }
        }

        findings.sort(Comparator
            .comparingInt((Finding finding) -> finding.addresses.size()).reversed()
            .thenComparing(finding -> finding.function.getEntryPoint()));

        try (PrintWriter output = new PrintWriter(new File(args[0]))) {
            for (Finding finding : findings) {
                output.printf("score=%d %s @ %s (%d bytes): ",
                    finding.addresses.size(),
                    finding.function.getName(),
                    finding.function.getEntryPoint(),
                    finding.function.getBody().getNumAddresses());

                List<Integer> values = new ArrayList<>(finding.addresses.keySet());
                values.sort(Integer::compareTo);
                for (int value : values) {
                    output.printf("%02x[", value);
                    List<Address> addresses = finding.addresses.get(value);
                    for (int index = 0; index < addresses.size(); index++) {
                        if (index != 0) {
                            output.print(",");
                        }
                        output.print(addresses.get(index));
                    }
                    output.print("] ");
                }
                output.println();
            }
        }
    }
}
