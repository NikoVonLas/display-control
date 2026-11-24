#!/usr/bin/env python3
"""Dump selected .NET methods with metadata tokens resolved to names.

This is a small research helper for inspecting the official Acer updater. It
requires the temporary `dnfile` and `dncil` packages; it does not execute the
Windows program.
"""

from __future__ import annotations

import argparse

import dnfile
from dncil.cil.body.reader import read_method_body_from_bytes
from dncil.clr.token import Token


TABLE_NAMES = {
    0x01: "Module",
    0x02: "TypeRef",
    0x04: "Field",
    0x06: "MethodDef",
    0x08: "Param",
    0x0A: "MemberRef",
    0x1B: "TypeSpec",
    0x2B: "MethodSpec",
}


def resolve_token(pe: dnfile.dnPE, token: Token) -> str:
    value = token.value
    table_number = value >> 24
    row_number = value & 0x00FFFFFF

    if table_number == 0x70:
        item = pe.net.user_strings.get(row_number)
        return repr(str(item))

    table_name = TABLE_NAMES.get(table_number)
    if not table_name:
        return str(token)

    table = getattr(pe.net.mdtables, table_name, None)
    if table is None or row_number == 0 or row_number > len(table.rows):
        return str(token)

    row = table.rows[row_number - 1]
    name = getattr(row, "Name", None)
    if name is None:
        return f"{table_name}[{row_number}]"

    owner = ""
    parent = getattr(row, "Class", None)
    parent_row = getattr(parent, "row", None)
    parent_name = getattr(parent_row, "TypeName", None) or getattr(parent_row, "Name", None)
    if parent_name:
        owner = f"{parent_name}."
    return f"{owner}{name}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("assembly")
    parser.add_argument("methods", nargs="+")
    args = parser.parse_args()

    pe = dnfile.dnPE(args.assembly)
    wanted = set(args.methods)
    found = set()

    for row_number, method in enumerate(pe.net.mdtables.MethodDef.rows, start=1):
        name = str(method.Name)
        if name not in wanted:
            continue
        found.add(name)
        print(f"\n.method 0x0600{row_number:04X} {name} RVA=0x{method.Rva:X}")
        body = read_method_body_from_bytes(pe.get_data(method.Rva))
        for instruction in body.instructions:
            operand = instruction.operand
            if isinstance(operand, Token):
                operand_text = resolve_token(pe, operand)
            elif operand is None:
                operand_text = ""
            else:
                operand_text = str(operand)
            print(f"IL_{instruction.offset:04X}: {instruction.opcode.name:<14} {operand_text}")

    missing = wanted - found
    if missing:
        parser.error("method(s) not found: " + ", ".join(sorted(missing)))


if __name__ == "__main__":
    main()
