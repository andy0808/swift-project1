//
//  BinarySection.swift
//  static_linker
//
//  Created by Simon Evans on 26/11/2015.
//  Copyright © 2015 Simon Evans. All rights reserved.
//

import Foundation


class BinarySection {
    let sectionType:   Section
    var baseAddress:   UInt64 = 0               // base address of this section
    var startAddress:  UInt64 = 0               // base address of complete binary (--baseAddress argument)
    var currentOffset: UInt64 = 0
    var sectionData    = NSMutableData()
    var relocations:   [(LoadCommandSegmentSection64, FileInfo)] = []


    init(_ type: Section) {
        sectionType = type
    }


    func align(addr: UInt64, alignment: UInt64) -> UInt64 {
        if (alignment > 0) {
            let mask = alignment - 1
            return (addr + mask) & ~mask
        }
        return addr
    }


    // alignment is log2 eg 0=>1, 1=>2 etc
    private func expandSectionToAlignment(alignment: Int) {
        let alignSize = UInt64(1 << alignment)
        let padding = Int(align(UInt64(sectionData.length), alignment:alignSize)) - sectionData.length
        if padding > 0 {
            let fillerByte: UInt8 = (sectionType == .TEXT) ? 0x90 : 0x00
            let filler = Array<UInt8>(count:padding, repeatedValue:UInt8(fillerByte))
            sectionData.appendData(NSData(bytes:filler, length:padding))
        }
    }

    /***
     func ptrToSpace<T>(addr: UInt64, count: Int) throws -> UnsafeMutableBufferPointer<T> {
     guard count > 0 && UInt64(sectionData.length) >= (addr + UInt64(count*(sizeof(T)))) else {
     throw LinkerError.UnrecoverableError(reason: "address/count is out of bounds")
     }
     let ptr = UnsafeMutablePointer<T>(sectionData.bytes + Int(addr))
     return UnsafeMutableBufferPointer<T>(start: ptr, count: count)
     }***/


    func reserveSpace<T>(count: Int, align: Int) -> (UInt64, UnsafeMutableBufferPointer<T>) {
        let size = count * sizeof(T)
        let space = NSMutableData()
        space.increaseLengthBy(size)
        expandSectionToAlignment(align)

        let addr = UInt64(sectionData.length)
        sectionData.appendData(space)
        currentOffset = UInt64(sectionData.length)

        let ptr = UnsafeMutablePointer<T>(sectionData.bytes + Int(addr))
        let buffer = UnsafeMutableBufferPointer<T>(start: ptr, count: count)

        return (addr, buffer)
    }


    private func addSymbols(fileInfo: FileInfo, pc: UInt64, sectionNumber: Int, sectionAddr: UInt64,
        offset: Int, count: Int) throws {
            let dupes = Set(["__ZL11unreachablePKc", "__ZN5swiftL11STDLIB_NAMEE", "__ZN5swiftL20MANGLING_MODULE_OBJCE", "__ZN5swiftL17MANGLING_MODULE_CE", "GCC_except_table2"])
            let lastIdx = offset + count
            for symIdx in offset..<lastIdx {
                let symbol = fileInfo.machOFile.symbolTable.symbols[symIdx]
                if Int(symbol.sectionNumber) == sectionNumber && symbol.type != .UNDF {
                    if globalMap[symbol.name] == nil {
                        let address = (symbol.value - sectionAddr) + pc
                        globalMap[symbol.name] = SymbolInfo(name: symbol.name, section: sectionType,
                            address: address, isLocal: symbol.privateExternalBit, GOTAddress: nil, bssSize: nil)
                    } else {
                        if !dupes.contains(symbol.name) {
                            throw LinkerError.UnrecoverableError(reason: "Found \(symbol.name) already in globalMap")
                        }
                    }
                }
            }
    }


    func addSegment(segment: LoadCommandSegment64, fileInfo: FileInfo) throws -> (UInt64, UInt64) {
        print("Adding segment nr \(segment.segnumber): \(segment.segname)")
        expandSectionToAlignment(Int(segment.sections[0].align))
        let dataStart = UInt64(sectionData.length)

        // FIXME: currently doesnt check if zerofills are only at the end
        for section in segment.sections {
            guard let data = section.sectionData else {
                throw LinkerError.UnrecoverableError(reason: "Cant read data")
            }
            sectionData.appendData(data)

            // If there is a dynamic symbol table, use that to get a list of the declared symbols contained in the obj/lib
            if fileInfo.machOFile.dySymbolTable != nil {
                // Add in exported symbols
                try addSymbols(fileInfo, pc: dataStart, sectionNumber: section.sectionNumber, sectionAddr: section.addr,
                    offset: Int(fileInfo.machOFile.dySymbolTable!.idxExtDefSym),
                    count: Int(fileInfo.machOFile.dySymbolTable!.numExtDefSym))

                // Add in local symbols
                try addSymbols(fileInfo, pc: dataStart, sectionNumber: section.sectionNumber, sectionAddr: section.addr,
                    offset: Int(fileInfo.machOFile.dySymbolTable!.idxLocalSym),
                    count:Int(fileInfo.machOFile.dySymbolTable!.numLocalSym))
            }
        }
        let dataSize = UInt64(sectionData.length) - dataStart



        return (dataStart, dataSize)
    }


    func addSection(segment: LoadCommandSegment64, section: LoadCommandSegmentSection64, fileInfo: FileInfo) throws -> UInt64 {
        print("Adding section nr \(section.sectionNumber): \(section.segmentName):\(section.sectionName)")

        // Pad section upto next alignment
        expandSectionToAlignment(Int(section.align))
        let sectionStart = UInt64(sectionData.length)   // the current 'program counter' for this section

        if (section.sectionType == .S_ZEROFILL) {
            print("Adding \(section.size) bytes of zerofill")
            sectionData.increaseLengthBy(Int(section.size))
        } else {
            guard let data = section.sectionData else {
                throw LinkerError.UnrecoverableError(reason: "Cant read data")
            }
            sectionData.appendData(data)
        }

        try addSymbols(fileInfo, pc: sectionStart, sectionNumber: section.sectionNumber, sectionAddr: section.addr,
            offset: 0, count: fileInfo.machOFile.symbolTable.symbols.count)

        let tuple = (section, fileInfo)
        relocations.append(tuple)
        currentOffset = UInt64(sectionData.length)

        return sectionStart
    }


    // Look through all of the relocations and find any symbols that are via the GOT and so may need a GOT entry
    func findGOTSymbols() throws -> Set<String> {
        var result: Set<String> = []

        for (section, fileInfo) in relocations {
            guard let relocs = section.relocations else {
                throw LinkerError.UnrecoverableError(reason: "Null relocations")
            }
            let symbols = fileInfo.machOFile.symbolTable.symbols

            for reloc in relocs {
                if reloc.type == .X86_64_RELOC_GOT || reloc.type == .X86_64_RELOC_GOT_LOAD {
                    guard reloc.extern else {
                        throw LinkerError.UnrecoverableError(reason: "Found GOT relocation that is not external")
                    }
                    guard let symbolName: String! = symbols[Int(reloc.symbolNum)].name else {
                        throw LinkerError.UnrecoverableError(reason: "Missing symbol")
                    }
                    result.insert(symbolName)
                }
            }
        }

        return result
    }


    func relocate() throws {
        for (section, fileInfo) in relocations {
            try relocateSection(section, fileInfo)
        }
    }


    func patchAddress(offset offset: Int, length: Int, address: Int64, absolute: Bool) throws {
        guard (offset + length) <= sectionData.length else {
            throw LinkerError.UnrecoverableError(reason: "Bad offset \(offset + length) > \(sectionData.length)")
        }
        // Pointer to the bytes in the data to actually update
        let relocAddr = UnsafePointer<Void>(sectionData.bytes + offset)

        switch (length) {
        case 1:
            guard address <= Int64(Int8.max) else {
                throw LinkerError.UnrecoverableError(reason: "Bad address \(address) for Int8")
            }
            let ptr = UnsafeMutablePointer<Int8>(relocAddr)
            guard absolute == false || ptr.memory == 0 else {
                throw LinkerError.UnrecoverableError(reason: "Addend found in absolute patch")
            }
            ptr.memory += Int8(address)


        case 2:
            guard address <= Int64(Int16.max) else {
                throw LinkerError.UnrecoverableError(reason: "Bad address \(address) for Int16")
            }
            let ptr = UnsafeMutablePointer<Int16>(relocAddr)
            guard absolute == false || ptr.memory == 0 else {
                throw LinkerError.UnrecoverableError(reason: "Addend found in absolute patch")
            }
            ptr.memory = (Int16(littleEndian: ptr.memory) + Int16(address)).littleEndian


        case 4:
            guard address <= Int64(Int32.max) else {
                throw LinkerError.UnrecoverableError(reason: "Bad address \(address) for Int32")
            }
            let ptr = UnsafeMutablePointer<Int32>(relocAddr)
            guard absolute == false || ptr.memory == 0 else {
                throw LinkerError.UnrecoverableError(reason: "Addend found in absolute patch")
            }
            ptr.memory = (Int32(littleEndian: ptr.memory) + Int32(address)).littleEndian


        case 8:
            let ptr = UnsafeMutablePointer<Int64>(relocAddr)
            guard absolute == false || ptr.memory == 0 else {
                throw LinkerError.UnrecoverableError(reason: "Addend found in absolute patch")
            }
            ptr.memory = (Int64(littleEndian: ptr.memory) + address).littleEndian


        default:
            throw LinkerError.UnrecoverableError(reason: "Invalid symbol relocation length \(length)")
        }
    }


    func relocateSection(section: LoadCommandSegmentSection64, _ fileInfo: FileInfo) throws {

        guard let relocs = section.relocations else {
            throw LinkerError.UnrecoverableError(reason: "Null relocations")
        }

        if relocs.count == 0 {
            return
        }
        for reloc in relocs {
            // Offset into the bytes of this segment that will updated
            let offset = Int(reloc.address) + Int(fileInfo.sectionBaseAddrs[section.sectionNumber]!)
            let length = Int(1 << reloc.length) // Number of bytes to modify
            let pc = (baseAddress + UInt64(offset + length))
            var address: Int64 = 0              // The value to be patched into memory


            func externalSymbol() throws -> SymbolInfo {
                guard reloc.extern else {
                    throw LinkerError.UnrecoverableError(reason: "Not an external reloc")
                }
                let symbols = fileInfo.machOFile.symbolTable.symbols
                let symbolName: String? = reloc.extern ? symbols[Int(reloc.symbolNum)].name : nil
                guard let symbol = globalMap[symbolName!] else {
                    throw LinkerError.UnrecoverableError(reason: "Undefined symbol: \(symbolName!)")
                }
                return symbol
            }


            switch reloc.type {
            case .X86_64_RELOC_BRANCH, .X86_64_RELOC_SIGNED:
                guard reloc.PCRelative == true else {
                    throw LinkerError.UnrecoverableError(reason: "reloc is not PCRelative")
                }

                if reloc.extern {
                    // Target is a symbol
                    guard reloc.PCRelative else {
                        throw LinkerError.UnrecoverableError(reason: "PCRelative == false not allowed")
                    }

                    let symbol = try externalSymbol()
                    address = Int64(symbol.address) - Int64(pc)
                } else {
                    // Target is in another section
                    let section = Int(reloc.symbolNum)

                    // Where the section was originally supposed to go
                    let oldAddr = fileInfo.machOFile.loadCommandSections[section-1].addr
                    address = Int64(fileInfo.offsetInSegment[section]!) - Int64(oldAddr)
                }
                try patchAddress(offset: offset, length: length, address: address, absolute: false)


            case .X86_64_RELOC_UNSIGNED:
                guard reloc.PCRelative == false else {
                    throw LinkerError.UnrecoverableError(reason: "PCRelative == true not allowed")
                }
                guard reloc.length == 2 || reloc.length == 3 else {
                    throw LinkerError.UnrecoverableError(reason: "Bad reloc length \(reloc.length) for RELOC_UNSIGNED")
                }
                if (reloc.extern) {
                    let symbol = try externalSymbol()
                    address = Int64(symbol.address)

                } else {
                    // Target is in another section
                    let section = Int(reloc.symbolNum)

                    // Where the section was originally supposed to go
                    let oldAddr = fileInfo.machOFile.loadCommandSections[section-1].addr
                    let symAddr = fileInfo.sectionBaseAddrs[section]! + startAddress
                    address = Int64(symAddr - oldAddr)
                }
                try patchAddress(offset: offset, length: length, address: address, absolute: false)


            case .X86_64_RELOC_GOT, .X86_64_RELOC_GOT_LOAD:
                guard reloc.PCRelative else {
                    throw LinkerError.UnrecoverableError(reason: "PCRelative == false not allowed")
                }
                guard reloc.length == 2 else {
                    throw LinkerError.UnrecoverableError(reason: "Bad reloc length \(reloc.length) for GOT reloc")
                }

                let symbol = try externalSymbol()
                guard let saddr = symbol.GOTAddress else {
                    throw LinkerError.UnrecoverableError(reason: "\(symbol.name) does not have a GOT address")
                }
                let address = Int64(saddr) - Int64(pc) // make PC relative
                try patchAddress(offset: offset, length: length, address: address, absolute: true)

            default:
                throw LinkerError.UnrecoverableError(reason: "Unsupported reloc type: \(reloc.type)")
            }
        }
    }
}
