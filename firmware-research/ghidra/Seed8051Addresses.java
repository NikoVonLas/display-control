// Disassembles explicit 8051 entry points and recursively follows direct calls.
// @category AcerFirmware

import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Set;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.RefType;
import ghidra.program.model.symbol.Reference;

public class Seed8051Addresses extends GhidraScript {
    @Override
    public void run() throws Exception {
        ArrayDeque<Address> pending = new ArrayDeque<>();
        Set<Address> visited = new HashSet<>();

        for (String value : getScriptArgs()) {
            pending.add(toAddr(Long.decode(value)));
        }

        while (!pending.isEmpty() && !monitor.isCancelled()) {
            Address entry = pending.removeFirst();
            if (!visited.add(entry) || !currentProgram.getMemory().contains(entry)) {
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

        println("Explicit entries visited: " + visited.size());
    }
}
