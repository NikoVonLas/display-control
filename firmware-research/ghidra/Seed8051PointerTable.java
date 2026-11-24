// Disassembles the functions referenced by a table of 3-byte far pointers.
//
// Arguments:
//   table address (for example 0x827b)
//   maximum number of entries (optional, defaults to 256)
//   expected bank byte (optional, defaults to 0xff)
//
// The Acer XV282K OSD state table stores entries as bank, address-high,
// address-low.  The bank byte is 0xff for functions in the current bank.
// @category AcerFirmware

import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Set;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.RefType;
import ghidra.program.model.symbol.Reference;

public class Seed8051PointerTable extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length == 0) {
            throw new IllegalArgumentException("table address is required");
        }

        long tableOffset = Long.decode(args[0]);
        int maximumEntries = args.length > 1 ? Integer.decode(args[1]) : 256;
        int expectedBank = args.length > 2 ? Integer.decode(args[2]) : 0xff;

        Memory memory = currentProgram.getMemory();
        ArrayDeque<Address> pending = new ArrayDeque<>();
        Set<Address> visited = new HashSet<>();
        int tableEntries = 0;

        for (int index = 0; index < maximumEntries; index++) {
            Address entry = toAddr(tableOffset + index * 3L);
            if (!memory.contains(entry.add(2))) {
                break;
            }

            int bank = memory.getByte(entry) & 0xff;
            if (bank != expectedBank) {
                break;
            }

            int high = memory.getByte(entry.add(1)) & 0xff;
            int low = memory.getByte(entry.add(2)) & 0xff;
            Address target = toAddr((high << 8) | low);
            if (memory.contains(target)) {
                pending.add(target);
            }
            tableEntries++;
        }

        while (!pending.isEmpty() && !monitor.isCancelled()) {
            Address entry = pending.removeFirst();
            if (!visited.add(entry) || !memory.contains(entry)) {
                continue;
            }

            disassemble(entry);
            Function function = getFunctionContaining(entry);
            if (function == null || !function.getEntryPoint().equals(entry)) {
                function = createFunction(entry, null);
            }
            if (function == null) {
                println("Could not create function at " + entry);
                continue;
            }

            InstructionIterator instructions =
                currentProgram.getListing().getInstructions(function.getBody(), true);
            for (Instruction instruction : instructions) {
                for (Reference reference : instruction.getReferencesFrom()) {
                    RefType type = reference.getReferenceType();
                    if (type.isCall()) {
                        pending.add(reference.getToAddress());
                    }
                }
            }
        }

        println("Pointer table entries: " + tableEntries);
        println("Function entries visited: " + visited.size());
    }
}
