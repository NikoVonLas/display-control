// Dumps every discovered function and its decompiled representation.
// @category AcerFirmware

import java.io.File;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

public class DumpFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            throw new IllegalArgumentException("Expected output file path");
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.setSimplificationStyle("decompile");
        if (!decompiler.openProgram(currentProgram)) {
            throw new IllegalStateException("Decompiler could not open the program");
        }

        try (PrintWriter output = new PrintWriter(new File(args[0]))) {
            FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
            for (Function function : functions) {
                if (monitor.isCancelled()) {
                    break;
                }

                output.printf(
                    "\n===== %s @ %s (%d bytes) =====%n",
                    function.getName(),
                    function.getEntryPoint(),
                    function.getBody().getNumAddresses()
                );

                DecompileResults results = decompiler.decompileFunction(function, 60, monitor);
                if (results.decompileCompleted() && results.getDecompiledFunction() != null) {
                    output.println(results.getDecompiledFunction().getC());
                } else {
                    output.printf("<decompile failed: %s>%n", results.getErrorMessage());
                }
            }
        } finally {
            decompiler.dispose();
        }
    }
}
