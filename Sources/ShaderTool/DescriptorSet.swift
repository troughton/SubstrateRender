//
//  DescriptorSet.swift
//  
//
//  Created by Thomas Roughton on 7/12/19.
//

import Foundation
import Substrate
import SPIRV_Cross

final class DescriptorSet {
    static let setCount : Int = 8
    
    var passes : [RenderPass] = []
    var resources : [Resource] = [] // Sorted by construction
    var stages : RenderStages = []
    
    var name : String? = nil
    
    func isCompatible(with resources: ArraySlice<Resource>) -> Bool {
        // Heuristic: only say sets are compatible if they share at least two resources.
        var matchedResources = 0
        
        var i = 0
        var j = resources.startIndex
        
        while i < self.resources.count && j < resources.endIndex {
            if self.resources[i].binding.index < resources[j].binding.index {
                i += 1
            } else if self.resources[i].binding.index > resources[j].binding.index {
                j += 1
            } else {
                if self.resources[i].binding.arrayLength != resources[j].binding.arrayLength ||
                    self.resources[i].name != resources[j].name ||
                    self.resources[i].type != resources[j].type {
                    return false
                }
                
                matchedResources += 1
                
                i += 1
                j += 1
            }
        }
        
        return matchedResources >= 2
    }
    
    func addResources(_ resources: ArraySlice<Resource>) {
        var i = 0
        var j = resources.startIndex
        
        while i < self.resources.count && j < resources.endIndex {
            if self.resources[i].binding.index < resources[j].binding.index {
                i += 1
            } else if self.resources[i].binding.index > resources[j].binding.index {
                self.resources.insert(resources[j], at: i)
            } else {
                // The resources are the same.
                self.resources[i].stages.formUnion(resources[j].stages)
                self.stages.formUnion(resources[j].stages)
                
                i += 1
                j += 1
            }
        }
        
        self.resources.append(contentsOf: resources[j...])
        for resource in resources[j...] {
            self.stages.formUnion(resource.stages)
        }
    }
    
    func printStruct(to stream: inout ReflectionPrinter, typeLookup: TypeLookup, setIndex: Int) {
        if self.resources.isEmpty {
            return
        }
        
        stream.print("public struct \(self.name ?? "Set\(setIndex)") : ShaderDescriptorSet {")
                
        stream.print("public static let activeStages : RenderStages = \(self.stages)")
        stream.newLine()
        
        stream.print("@inlinable")
        stream.print("public init() {}")
        stream.newLine()
        
        // Print struct definitions
        let structDefs = typeLookup.typeContexts.compactMap { (type, context) -> SPIRVType? in
            guard case .descriptorSet(let set) = context, set === self else { return nil }
            return type
        }.sorted(by: { $0.name < $1.name })
        
        for type in structDefs {
            stream.print(type.declaration)
            stream.newLine()
        }
        
        for resource in self.resources {
            if resource.viewType == .uniformBuffer {
                stream.print("@BufferBacked public var \(resource.name) : \(resource.type.name)? = nil")
            } else {
                let wrapperType = resource.viewType == .uniformBuffer || resource.viewType == .storageBuffer ? "@OffsetView " : ""
                if wrapperType.isEmpty, resource.binding.arrayLength > 1 { // FIXME: how do we handle this case for arrays which require property wrappers?
                    stream.print("\(wrapperType)public var \(resource.name) : [\(resource.viewType.substrateTypeName)?] = .init(repeating: nil, count: \(resource.binding.arrayLength))")
                } else {
                    stream.print("\(wrapperType)public var \(resource.name) : \(resource.viewType.substrateTypeName)? = nil")
                }
            }
        }
        
        stream.newLine()
        
        stream.print("public mutating func encode(into argBuffer: ArgumentBuffer, setIndex: Int, bindingEncoder: ResourceBindingEncoder? = nil) {")

        // Metal 
        do {
            stream.print("#if canImport(Metal)")
            stream.print("if RenderBackend.api == .metal {")
            if self.resources.contains(where: { $0.viewType == .storageImage || $0.platformBindings.macOSMetalIndex != $0.platformBindings.appleSiliconMetalIndex }) {
                stream.print("#if (os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(macCatalyst)")
                stream.print("let isAppleSiliconGPU = true")
                stream.print("#elseif arch(i386) || arch(x86_64)")
                stream.print("let isAppleSiliconGPU = false")
                stream.print("#else")
                stream.print("let isAppleSiliconGPU = (RenderBackend.renderDevice as! MTLDevice).isAppleSiliconGPU")
                stream.print("#endif")
            }
            defer { 
                stream.print("}")
                stream.print("#endif // canImport(Metal)")
            }

            for resource in self.resources {
                if resource.viewType == .uniformBuffer {
                    // @BufferBacked property
                    
                    stream.print("if let resource = self.$\(resource.name).buffer {")
                                    
                    stream.print("argBuffer.bindings.append(")
                    stream.print("(ResourceBindingPath(descriptorSet: setIndex, index: \(resource.binding.index), type: .buffer), .buffer(resource.wrappedValue, offset: resource.offset))")
                    
                    stream.print(")")
                    stream.print("}")
                    
                    continue
                }
                
                let arrayIndexString : String
                if resource.binding.arrayLength > 1 {
                    arrayIndexString = " + i"
                    stream.print("for i in 0..<\(resource.binding.arrayLength) {")
                    stream.print("if let resource = self.\(resource.name)[i] {")
                } else {
                    arrayIndexString = ""
                    stream.print("if let resource = self.\(resource.name) {")
                }
                
                let addArgBufferBinding = { (stream: inout ReflectionPrinter, index: Int) in
                    stream.print("argBuffer.bindings.append(")
                    
                    var type = resource.type
                    if case .array(let elementType, let length) = type {
                        switch elementType {
                        case  .buffer, .texture, .sampler:
                            assert(length == resource.binding.arrayLength)
                            type = elementType
                        default:
                            break
                        }
                    }
                    
                    switch type {
                    case .texture:
                        stream.print("(ResourceBindingPath(descriptorSet: setIndex, index: \(index)\(arrayIndexString), type: .texture), .texture(resource))")
                    case .sampler:
                        stream.print("(ResourceBindingPath(descriptorSet: setIndex, index: \(index)\(arrayIndexString), type: .sampler), .sampler(resource))")
                    default:
                        stream.print("(ResourceBindingPath(descriptorSet: setIndex, index: \(index)\(arrayIndexString), type: .buffer), .buffer(resource, offset: self.$\(resource.name).offset))")
                    }
                    
                    stream.print(")")
                }
                
                if resource.viewType == .storageImage || resource.platformBindings.macOSMetalIndex != resource.platformBindings.appleSiliconMetalIndex {
                    stream.print("if isAppleSiliconGPU {")
                    // Storage images (i.e. read-write textures) aren't permitted in argument buffers, so we need to bind directly on the encoder.
                    if resource.viewType == .storageImage, let index = resource.platformBindings.appleSiliconMetalIndex {
                        stream.print("if let bindingEncoder = bindingEncoder {")
                        stream.print("bindingEncoder.setTexture(resource, key: MetalIndexedFunctionArgument(type: .texture, index: \(index)\(arrayIndexString), stages: \(resource.stages)))")
                        stream.print("}")
                    } else {
                        if let index = resource.platformBindings.appleSiliconMetalIndex.map({ Int($0) }) {
                            addArgBufferBinding(&stream, index)
                        }
                    }
                    stream.print("} else {")
                    
                    let index = resource.platformBindings.macOSMetalIndex.map { Int($0) } ?? resource.binding.index
                    addArgBufferBinding(&stream, index)
                    
                    stream.print("}")
                    
                } else {
                    let index = resource.platformBindings.macOSMetalIndex.map { Int($0) } ?? resource.binding.index
                    addArgBufferBinding(&stream, index)
                }
               
                stream.print("}")
                
                if resource.binding.arrayLength > 1 {
                    stream.print("}")
                }
            }
        }

        stream.newLine()

        // Vulkan
        do {
            stream.print("#if canImport(Vulkan)")
            stream.print("if RenderBackend.api == .vulkan {")
            defer {
                stream.print("}")
                stream.print("#endif // canImport(Vulkan)")
            }

            for resource in self.resources {
                if resource.viewType == .uniformBuffer {
                    // @BufferBacked property
                    
                    stream.print("if let resource = self.$\(resource.name).buffer {")
                    stream.print("argBuffer.bindings.append(")
                    stream.print("(ResourceBindingPath(set: UInt32(setIndex), binding: \(resource.binding.index), arrayIndex: 0), .buffer(resource.wrappedValue, offset: resource.offset))")
                    
                    stream.print(")")
                    stream.print("}")
                    
                    continue
                }
                
                var type = resource.type
                if case .array(let elementType, let length) = type {
                    switch elementType {
                    case  .buffer, .texture, .sampler:
                        assert(length == resource.binding.arrayLength)
                        type = elementType
                    default:
                        break
                    }
                }
                
                let arrayIndexString : String
                if resource.binding.arrayLength > 1 {
                    arrayIndexString = "UInt32(i)"
                    stream.print("for i in 0..<\(resource.binding.arrayLength) {")
                    stream.print("if let resource = self.\(resource.name)[i] {")
                } else {
                    arrayIndexString = "0"
                    stream.print("if let resource = self.\(resource.name) {")
                }
                
                stream.print("argBuffer.bindings.append(")
                
                switch type {
                case .texture:
                    stream.print("(ResourceBindingPath(set: UInt32(setIndex), binding: \(resource.binding.index), arrayIndex: \(arrayIndexString)), .texture(resource))")
                case .sampler:
                    stream.print("(ResourceBindingPath(set: UInt32(setIndex), binding: \(resource.binding.index), arrayIndex: \(arrayIndexString)), .sampler(resource))")
                default:
                    stream.print("(ResourceBindingPath(set: UInt32(setIndex), binding: \(resource.binding.index), arrayIndex: \(arrayIndexString)), .buffer(resource, offset: self.$\(resource.name).offset))")
                }
                
                stream.print(")")
                stream.print("}")

                if resource.binding.arrayLength > 1 {
                    stream.print("}")
                }
            }
        }
        
        stream.print("}")
        stream.print("}")
        stream.newLine()
    }
}

