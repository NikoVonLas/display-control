// Seeds recursive disassembly and creates functions at every direct call target.
// @category AcerFirmware

import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Set;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.RefType;
import ghidra.program.model.symbol.Reference;

public class Bootstrap8051 extends GhidraScript {
    private static final long[] VECTOR_AND_SEED_ADDRESSES = {
        0x0000, 0x0003, 0x000b, 0x0013, 0x001b, 0x0023, 0x002b,
        0x4e50, 0x5187, 0x500b, 0x5325, 0x535d,
        0x0b57, 0x0ba3, 0x0bb6, 0x0bef, 0x0c15, 0x0c28, 0x0c4e, 0x0c61, 0x0c74, 0x0c87, 0x0c9a
    };

    @Override
    public void run() throws Exception {
        ArrayDeque<Address> pending = new ArrayDeque<>();
        Set<Address> visited = new HashSet<>();
        Set<Address> scannedFunctions = new HashSet<>();

        for (long value : VECTOR_AND_SEED_ADDRESSES) {
            pending.add(toAddr(value));
        }

        String[] args = getScriptArgs();
        int bank = args.length == 0 ? 17 : Integer.decode(args[0]);
        int bankThunk = 0x0b57 + bank * 0x13;
        Memory memory = currentProgram.getMemory();
        for (int offset = 0; offset <= 0x3ffa; offset++) {
            Address address = toAddr(offset);
            if ((memory.getByte(address) & 0xff) == 0x90 &&
                (memory.getByte(address.add(3)) & 0xff) == 0x02 &&
                (memory.getByte(address.add(4)) & 0xff) == ((bankThunk >> 8) & 0xff) &&
                (memory.getByte(address.add(5)) & 0xff) == (bankThunk & 0xff)) {
                int target = ((memory.getByte(address.add(1)) & 0xff) << 8) |
                    (memory.getByte(address.add(2)) & 0xff);
                pending.add(toAddr(target));
            }
        }

        while (!pending.isEmpty() && !monitor.isCancelled()) {
            Address entry = pending.removeFirst();
            if (!visited.add(entry) || !currentProgram.getMemory().contains(entry)) {
                continue;
            }

            disassemble(entry);
            if (getFunctionAt(entry) == null) {
                createFunction(entry, null);
            }

            FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
            for (Function function : functions) {
                if (!scannedFunctions.add(function.getEntryPoint())) {
                    continue;
                }

                InstructionIterator instructions = currentProgram.getListing().getInstructions(function.getBody(), true);
                for (Instruction instruction : instructions) {
                    for (Reference reference : instruction.getReferencesFrom()) {
                        RefType type = reference.getReferenceType();
                        if (type.isCall()) {
                            pending.add(reference.getToAddress());
                        }
                    }
                }
            }
        }

        println("Seeded functions: " + currentProgram.getFunctionManager().getFunctionCount());
    }
}
