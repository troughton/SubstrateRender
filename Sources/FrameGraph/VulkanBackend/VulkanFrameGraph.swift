//
//  VkFrameGraphContext.swift
//  VkRenderer
//
//  Created by Joseph Bennett on 2/01/18.
//

#if canImport(Vulkan)
import Vulkan
import Dispatch
import FrameGraphCExtras
import FrameGraphUtilities

public final class VulkanFrameGraphContext : _FrameGraphContext {
    public var accessSemaphore: Semaphore
    
    let backend : VulkanBackend
    let resourceRegistry : VulkanTransientResourceRegistry
    let commandPool : VulkanCommandPool
    let commandGenerator: ResourceCommandGenerator<VulkanBackend>
    var compactedResourceCommands = [CompactedResourceCommand<VulkanCompactedResourceCommandType>]()
    
    var queueCommandBufferIndex : UInt64 = 0
    let syncSemaphore : VkSemaphore // A counting semaphore.
    
    public let transientRegistryIndex: Int
    var frameGraphQueue : Queue

    private let commandBufferResourcesQueue = DispatchQueue(label: "Command Buffer Resources management.")
    private var inactiveCommandBufferResources = [Unmanaged<CommandBufferResources>]()

    init(backend: VulkanBackend, inflightFrameCount: Int, transientRegistryIndex: Int) {
        self.backend = backend
        self.frameGraphQueue = Queue()
        self.commandPool = VulkanCommandPool(device: backend.device, inflightFrameCount: inflightFrameCount)
        self.transientRegistryIndex = transientRegistryIndex
        self.resourceRegistry = VulkanTransientResourceRegistry(device: backend.device, inflightFrameCount: inflightFrameCount, transientRegistryIndex: transientRegistryIndex, persistentRegistry: backend.resourceRegistry)
        self.accessSemaphore = Semaphore(value: Int32(inflightFrameCount))
        
        self.commandGenerator = ResourceCommandGenerator()
        
        var semaphoreTypeCreateInfo = VkSemaphoreTypeCreateInfo()
        semaphoreTypeCreateInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
        semaphoreTypeCreateInfo.initialValue = self.queueCommandBufferIndex
        semaphoreTypeCreateInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE
        
        var semaphore: VkSemaphore? = nil
        withUnsafePointer(to: semaphoreTypeCreateInfo) { semaphoreTypeCreateInfo in
            var semaphoreCreateInfo = VkSemaphoreCreateInfo()
            semaphoreCreateInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
            semaphoreCreateInfo.pNext = UnsafeRawPointer(semaphoreTypeCreateInfo)
            vkCreateSemaphore(backend.device.vkDevice, &semaphoreCreateInfo, nil, &semaphore)
        }
        self.syncSemaphore = semaphore!
        
        backend.queueSyncSemaphores[Int(self.frameGraphQueue.index)] = self.syncSemaphore
    }

    // Thread-safe.
    public func markCommandBufferResourcesCompleted(_ resources: [CommandBufferResources]) {
        self.commandBufferResourcesQueue.sync {
            for resource in resources {
                self.inactiveCommandBufferResources.append(Unmanaged.passRetained(resource))
            }
        }
    }  

    public func beginFrameResourceAccess() {
        self.backend.setActiveContext(self)
    }
    
    var resourceMap : FrameResourceMap<VulkanBackend> {
        return FrameResourceMap<VulkanBackend>(persistentRegistry: self.backend.resourceRegistry, transientRegistry: self.resourceRegistry)
    }

    // We need to make sure the resources are released on the main Vulkan thread.
    func clearInactiveCommandBufferResources() {
        var inactiveResources : [Unmanaged<CommandBufferResources>]? = nil
        self.commandBufferResourcesQueue.sync {
            inactiveResources = self.inactiveCommandBufferResources
            self.inactiveCommandBufferResources.removeAll()
        }
        for resource in inactiveResources! {
            resource.release()
        }
    }
    
    static func encoderCommandBufferIndices(passes: [RenderPassRecord], commandEncoderIndices: [Int], commandEncoderCount: Int) -> [Int] {
        
        var encoderAttributes = [(isExternal: Bool, usesWindowTexture: Bool)](repeating: (false, false), count: commandEncoderCount)
        for (i, pass) in passes.enumerated() {
            let encoderIndex = commandEncoderIndices[i]
            encoderAttributes[encoderIndex].isExternal = pass.pass.passType == .external
            encoderAttributes[encoderIndex].usesWindowTexture = encoderAttributes[encoderIndex].usesWindowTexture || pass.usesWindowTexture
        }
        
        var encoderCommandBufferIndices = [Int](repeating: 0, count: commandEncoderCount)
        var currentCBIndex = 0
        
        for (i, attributes) in encoderAttributes.enumerated().dropFirst() {
            if encoderAttributes[i - 1] != attributes {
                currentCBIndex += 1
            }
            encoderCommandBufferIndices[i] = currentCBIndex
        }
        
        return encoderCommandBufferIndices
    }
    
    static var resourceCommandArrayTag: TaggedHeap.Tag {
        return UInt64(bitPattern: Int64("FrameGraph Compacted Resource Commands".hashValue))
    }
    
    func generateCompactedResourceCommands(commandInfo: FrameCommandInfo<VulkanBackend>, commandGenerator: ResourceCommandGenerator<VulkanBackend>) {
        fatalError()
    }
    
    public func executeFrameGraph(passes: [RenderPassRecord], dependencyTable: DependencyTable<DependencyType>, resourceUsages: ResourceUsages, completion: @escaping () -> Void) {
        self.clearInactiveCommandBufferResources()
        self.resourceRegistry.prepareFrame()
        
        defer {
            TaggedHeap.free(tag: Self.resourceCommandArrayTag)
            
            self.resourceRegistry.cycleFrames()
            
            self.commandGenerator.reset()
            self.compactedResourceCommands.removeAll(keepingCapacity: true)
            
            assert(self.backend.activeContext === self)
            self.backend.activeContext = nil
        }
        
        if passes.isEmpty {
            completion()
            self.accessSemaphore.signal()
            return
        }
        
        var frameCommandInfo = FrameCommandInfo<VulkanBackend>(passes: passes, resourceUsages: resourceUsages, initialCommandBufferSignalValue: self.queueCommandBufferIndex + 1)
        self.commandGenerator.generateCommands(passes: passes, resourceUsages: resourceUsages, transientRegistry: self.resourceRegistry, frameCommandInfo: &frameCommandInfo)
        self.commandGenerator.executePreFrameCommands(queue: self.frameGraphQueue, resourceMap: self.resourceMap, frameCommandInfo: &frameCommandInfo)
        self.generateCompactedResourceCommands(commandInfo: frameCommandInfo, commandGenerator: self.commandGenerator)
        
        let encoderManager = EncoderManager(frameGraph: self)
        
        for (i, passRecord) in passes.enumerated() {
            let passCommandEncoderIndex = frameCommandInfo.encoderIndex(for: passRecord)
            let passEncoderInfo = frameCommandInfo.commandEncoders[passCommandEncoderIndex]
            
            switch passRecord.pass.passType {
            case .blit:
                let commandEncoder = encoderManager.blitCommandEncoder()
                commandEncoder.executePass(passRecord, resourceCommands: compactedResourceCommands)
                
            case .draw:
                let commandEncoder = encoderManager.renderCommandEncoder(descriptor: passEncoderInfo.renderTargetDescriptor!)
                
                commandEncoder.executePass(passRecord, resourceCommands: compactedResourceCommands,  passRenderTarget: (passRecord.pass as! DrawRenderPass).renderTargetDescriptor)
                
            case .compute:
                let commandEncoder = encoderManager.computeCommandEncoder()
                commandEncoder.executePass(passRecord, resourceCommands: compactedResourceCommands)
                
            case .cpu, .external:
                break
            }
        }
        
        // Trigger callback once GPU is finished processing frame.
        encoderManager.endEncoding()
        
        fatalError("Need to wait on the counting semaphore associated with this queue - see Metal encodeSignalEvent and encodeWaitForEvent in MetalFrameGraphBackend.swift.")
        
        for swapChain in self.resourceRegistry.frameSwapChains {
            swapChain.submit()
        }
    }
    
//    func generateResourceCommands(passes: [RenderPassRecord], resourceUsages: ResourceUsages, renderTargetDescriptors: [VulkanRenderTargetDescriptor?], lastCommandBufferIndex: UInt64) {
//
//        resourceLoop: for resource in resourceUsages.allResources {
//            let usages = resource.usages
//            if usages.isEmpty { continue }
//
//            var usageIterator = usages.makeIterator()
//
//            // Find the first used render pass.
//            var previousUsage : ResourceUsage
//            repeat {
//                guard let usage = usageIterator.next() else {
//                    continue resourceLoop // no active usages for this resource
//                }
//                previousUsage = usage
//            } while !previousUsage.renderPassRecord.isActive || (previousUsage.stages == .cpuBeforeRender && previousUsage.type != .unusedArgumentBuffer)
//
//            let materialisePass = previousUsage.renderPassRecord.passIndex
//            let materialiseIndex = previousUsage.commandRange.lowerBound
//
//            while previousUsage.type == .unusedArgumentBuffer || previousUsage.type == .unusedRenderTarget {
//                previousUsage = usageIterator.next()!
//            }
//
//            let firstUsage = previousUsage
//
//            while let usage = usageIterator.next()  {
//                if !usage.renderPassRecord.isActive || usage.stages == .cpuBeforeRender { continue }
//                defer { previousUsage = usage }
//
//                if !previousUsage.isWrite && !usage.isWrite { continue }
//
//                if previousUsage.type == usage.type && previousUsage.type.isRenderTarget {
//                    continue
//                }
//
//                do {
//                    // Manage memory dependency.
//
//                    var isDepthStencil = false
//                    if let texture = resource.texture, texture.descriptor.pixelFormat.isDepth || texture.descriptor.pixelFormat.isStencil {
//                        isDepthStencil = true
//                    }
//
//                    let passUsage = previousUsage
//                    let dependentUsage = usage
//
//                    let passCommandIndex = passUsage.commandRange.upperBound - 1
//                    let dependentCommandIndex = dependentUsage.commandRange.lowerBound
//
//                    let sourceAccessMask = passUsage.type.accessMask(isDepthOrStencil: isDepthStencil)
//                    let destinationAccessMask = dependentUsage.type.accessMask(isDepthOrStencil: isDepthStencil)
//
//                    let sourceMask = passUsage.type.shaderStageMask(isDepthOrStencil: isDepthStencil, stages: passUsage.stages)
//                    let destinationMask = dependentUsage.type.shaderStageMask(isDepthOrStencil: isDepthStencil, stages: dependentUsage.stages)
//
//                    let sourceLayout = resource.type == .texture ? passUsage.type.imageLayout(isDepthOrStencil: isDepthStencil) : VK_IMAGE_LAYOUT_UNDEFINED
//                    let destinationLayout = resource.type == .texture ? dependentUsage.type.imageLayout(isDepthOrStencil: isDepthStencil) : VK_IMAGE_LAYOUT_UNDEFINED
//
//                    if !passUsage.type.isRenderTarget, dependentUsage.type.isRenderTarget,
//                        renderTargetDescriptors[passUsage.renderPassRecord.passIndex] !== renderTargetDescriptors[dependentUsage.renderPassRecord.passIndex] {
//                        renderTargetDescriptors[dependentUsage.renderPassRecord.passIndex]!.initialLayouts[resource.texture!] = sourceLayout
//                    }
//
//                    if passUsage.type.isRenderTarget, !dependentUsage.type.isRenderTarget,
//                        renderTargetDescriptors[passUsage.renderPassRecord.passIndex] !== renderTargetDescriptors[dependentUsage.renderPassRecord.passIndex] {
//                        renderTargetDescriptors[passUsage.renderPassRecord.passIndex]!.finalLayouts[resource.texture!] = destinationLayout
//                    }
//
//                    let barrier : ResourceMemoryBarrier
//
//                    if let texture = resource.texture {
//                        var imageBarrierInfo = VkImageMemoryBarrier()
//                        imageBarrierInfo.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
//                        imageBarrierInfo.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
//                        imageBarrierInfo.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
//                        imageBarrierInfo.srcAccessMask = VkAccessFlags(sourceAccessMask)
//                        imageBarrierInfo.dstAccessMask = VkAccessFlags(destinationAccessMask)
//                        imageBarrierInfo.oldLayout = sourceLayout
//                        imageBarrierInfo.newLayout = destinationLayout
//                        imageBarrierInfo.subresourceRange = VkImageSubresourceRange(aspectMask: texture.descriptor.pixelFormat.aspectFlags, baseMipLevel: 0, levelCount: UInt32(texture.descriptor.mipmapLevelCount), baseArrayLayer: 0, layerCount: UInt32(texture.descriptor.arrayLength))
//
//                        barrier = .texture(texture, imageBarrierInfo)
//                    } else if let buffer = resource.buffer {
//                        var bufferBarrierInfo = VkBufferMemoryBarrier()
//                        bufferBarrierInfo.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
//                        bufferBarrierInfo.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
//                        bufferBarrierInfo.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
//                        bufferBarrierInfo.srcAccessMask = VkAccessFlags(sourceAccessMask)
//                        bufferBarrierInfo.dstAccessMask = VkAccessFlags(destinationAccessMask)
//                        bufferBarrierInfo.offset = 0
//                        bufferBarrierInfo.size = VK_WHOLE_SIZE
//
//                        barrier = .buffer(buffer, bufferBarrierInfo)
//                    } else {
//                        fatalError()
//                    }
//
//                    var memoryBarrierInfo = MemoryBarrierInfo(sourceMask: sourceMask, destinationMask: destinationMask, barrier: barrier)
//
//                    if passUsage.renderPassRecord.pass.passType == .draw || dependentUsage.renderPassRecord.pass.passType == .draw {
//
//                        let renderTargetDescriptor = (renderTargetDescriptors[passUsage.renderPassRecord.passIndex] ?? renderTargetDescriptors[dependentUsage.renderPassRecord.passIndex])! // Add to the first pass if possible, the second pass if not.
//
//                        var subpassDependency = VkSubpassDependency()
//                        subpassDependency.dependencyFlags = 0 // FIXME: ideally should be VkDependencyFlags(VK_DEPENDENCY_BY_REGION_BIT) for all cases except temporal AA.
//                        if let passUsageSubpass = renderTargetDescriptor.subpassForPassIndex(passUsage.renderPassRecord.passIndex) {
//                            subpassDependency.srcSubpass = UInt32(passUsageSubpass.index)
//                        } else {
//                            subpassDependency.srcSubpass = VK_SUBPASS_EXTERNAL
//                        }
//                        subpassDependency.srcStageMask = VkPipelineStageFlags(sourceMask)
//                        subpassDependency.srcAccessMask = VkAccessFlags(sourceAccessMask)
//                        if let destinationUsageSubpass = renderTargetDescriptor.subpassForPassIndex(dependentUsage.renderPassRecord.passIndex) {
//                            subpassDependency.dstSubpass = UInt32(destinationUsageSubpass.index)
//                        } else {
//                            subpassDependency.dstSubpass = VK_SUBPASS_EXTERNAL
//                        }
//                        subpassDependency.dstStageMask = VkPipelineStageFlags(destinationMask)
//                        subpassDependency.dstAccessMask = VkAccessFlags(destinationAccessMask)
//
//                        // If the dependency is on an attachment, then we can let the subpass dependencies handle it, _unless_ both usages are in the same subpass.
//                        // Otherwise, an image should always be in the right layout when it's materialised. The only case it won't be is if it's used in one way in
//                        // a draw render pass (e.g. as a read texture) and then needs to transition layout before being used in a different type of pass.
//
//                        if subpassDependency.srcSubpass == subpassDependency.dstSubpass {
//                            guard case .texture(let textureHandle, var imageBarrierInfo) = barrier else {
//                                print("Source: \(passUsage), destination: \(dependentUsage)")
//                                fatalError("We can't insert pipeline barriers within render passes for buffers.")
//                            }
//
//                            if imageBarrierInfo.oldLayout != imageBarrierInfo.newLayout {
//                                imageBarrierInfo.oldLayout = VK_IMAGE_LAYOUT_GENERAL
//                                imageBarrierInfo.newLayout = VK_IMAGE_LAYOUT_GENERAL
//                                memoryBarrierInfo.barrier = .texture(textureHandle, imageBarrierInfo)
//                            }
//
//                            // Insert a subpass self-dependency.
//                            resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: dependentCommandIndex, order: .before))
//
//                            renderTargetDescriptor.addDependency(subpassDependency)
//                        } else if sourceLayout != destinationLayout, // guaranteed to not be a buffer since buffers have UNDEFINED image layouts above.
//                                    !passUsage.type.isRenderTarget, !dependentUsage.type.isRenderTarget {
//                            // We need to insert a pipeline barrier to handle a layout transition.
//                            // We can therefore avoid a subpass dependency in most cases.
//
//                            if subpassDependency.srcSubpass == VK_SUBPASS_EXTERNAL {
//                                // Insert a pipeline barrier before the start of the Render Command Encoder.
//                                let firstPassInVkRenderPass = renderTargetDescriptors[dependentUsage.renderPassRecord.passIndex]!.renderPasses.first!
//                                let dependencyIndex = firstPassInVkRenderPass.commandRange!.lowerBound
//
//                                assert(dependencyIndex <= dependentUsage.commandRange.lowerBound)
//
//                                resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: dependencyIndex, order: .before))
//                            } else if subpassDependency.dstSubpass == VK_SUBPASS_EXTERNAL {
//                                // Insert a pipeline barrier before the next command after the render command encoder ends.
//                                let lastPassInVkRenderPass = renderTargetDescriptors[dependentUsage.renderPassRecord.passIndex]!.renderPasses.last!
//                                let dependencyIndex = lastPassInVkRenderPass.commandRange!.upperBound
//
//                                assert(dependencyIndex <= passUsage.commandRange.lowerBound)
//
//                                resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: dependencyIndex, order: .before))
//                            } else {
//                                // Insert a subpass self-dependency and a pipeline barrier.
//                                fatalError("This should have been handled by the subpassDependency.srcSubpass == subpassDependency.dstSubpass case.")
//
//                                // resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: dependentCommandIndex, order: .before))
//                                // subpassDependency.srcSubpass = subpassDependency.dstSubpass
//                                // renderTargetDescriptor.addDependency(subpassDependency)
//                            }
//                        } else {
//                            // A subpass dependency should be enough to handle this case.
//                            renderTargetDescriptor.addDependency(subpassDependency)
//                        }
//
//                    } else {
//
//                        let event = FenceDependency(label: "Memory dependency for \(resource)", queue: self.frameGraphQueue, commandBufferIndex: lastCommandBufferIndex)
//
//                        if self.backend.device.physicalDevice.queueFamilyIndex(renderPassType: passUsage.renderPassRecord.pass.passType) != self.backend.device.physicalDevice.queueFamilyIndex(renderPassType: dependentUsage.renderPassRecord.pass.passType) {
//                            // Assume that the resource has a concurrent sharing mode.
//                            // If the sharing mode is concurrent, then we only need to insert a barrier for an image layout transition.
//                            // Otherwise, we would need to do a queue ownership transfer.
//
//                            // TODO: we should make all persistent resources concurrent if necessary, and all frame resources exclusive (unless they have two consecutive reads).
//                            // The logic here will then change to insert a pipeline barrier on each queue with an ownership transfer, unconditional on being a buffer or texture.
//
//                            if case .texture = barrier { // We only need to insert a barrier to do a layout transition.
//                                //  resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: passCommandIndex - 1, order: .after))
//                                resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: dependentCommandIndex, order: .before))
//                            }
//                            // Also use a semaphore, since they're on different queues
//                            resourceCommands.append(VulkanFrameResourceCommand(command: .signalEvent(event, afterStages: sourceMask), index: passCommandIndex, order: .after))
//                            resourceCommands.append(VulkanFrameResourceCommand(command: .waitForEvent(event, info: memoryBarrierInfo), index: dependentCommandIndex, order: .before))
//                        } else if previousUsage.isWrite || usage.isWrite {
//                            // If either of these take place within a render pass, they need to be inserted as pipeline barriers instead and added
//                            // as subpass dependencise if relevant.
//
//                            resourceCommands.append(VulkanFrameResourceCommand(command: .signalEvent(event, afterStages: sourceMask), index: passCommandIndex, order: .after))
//                            resourceCommands.append(VulkanFrameResourceCommand(command: .waitForEvent(event, info: memoryBarrierInfo), index: dependentCommandIndex, order: .before))
//                        } else if case .texture = barrier, sourceLayout != destinationLayout { // We only need to insert a barrier to do a layout transition.
//                            // TODO: We could minimise the number of layout transitions with a lookahead approach.
//                            resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: dependentCommandIndex, order: .before))
//                        }
//                    }
//
//                }
//            }
//
//            let lastUsage = previousUsage
//
//            let historyBufferCreationFrame = resource.flags.contains(.historyBuffer) && !resource.stateFlags.contains(.initialised)
//            let historyBufferUseFrame = resource.flags.contains(.historyBuffer) && resource.stateFlags.contains(.initialised)
//
//            // Insert commands to materialise and dispose of the resource.
//
//            if let buffer = resource.buffer {
//
//                var isModified = false
//                var queueFamilies : QueueFamilies = []
//                var bufferUsage : VkBufferUsageFlagBits = []
//
//                if buffer.flags.contains(.historyBuffer) {
//                    bufferUsage.formUnion(VkBufferUsageFlagBits(buffer.descriptor.usageHint))
//                }
//
//                for usage in usages where usage.renderPassRecord.isActive && usage.stages != .cpuBeforeRender {
//                    switch usage.renderPassRecord.pass.passType {
//                    case .draw:
//                        queueFamilies.formUnion(.graphics)
//                    case .compute:
//                        queueFamilies.formUnion(.compute)
//                    case .blit:
//                        queueFamilies.formUnion(.copy)
//                    case .cpu, .external:
//                        break
//                    }
//
//                    switch usage.type {
//                    case .constantBuffer:
//                        bufferUsage.formUnion(.uniformBuffer)
//                    case .read:
//                        bufferUsage.formUnion([.uniformTexelBuffer, .storageBuffer, .storageTexelBuffer])
//                    case .write, .readWrite:
//                        isModified = true
//                        bufferUsage.formUnion([.storageBuffer, .storageTexelBuffer])
//                    case .blitSource:
//                        bufferUsage.formUnion(.transferSource)
//                    case .blitDestination:
//                        isModified = true
//                        bufferUsage.formUnion(.transferDestination)
//                    case .blitSynchronisation:
//                        isModified = true
//                        bufferUsage.formUnion([.transferSource, .transferDestination])
//                    case .vertexBuffer:
//                        bufferUsage.formUnion(.vertexBuffer)
//                    case .indexBuffer:
//                        bufferUsage.formUnion(.indexBuffer)
//                    case .indirectBuffer:
//                        bufferUsage.formUnion(.indirectBuffer)
//                    case .readWriteRenderTarget, .writeOnlyRenderTarget, .inputAttachmentRenderTarget, .unusedRenderTarget, .sampler, .inputAttachment:
//                        fatalError()
//                    case .unusedArgumentBuffer:
//                        break
//                    }
//                }
//
//                preFrameResourceCommands.append(
//                    VulkanPreFrameResourceCommand(command:
//                        .materialiseBuffer(buffer, usage: bufferUsage),
//                                                  passIndex: firstUsage.renderPassRecord.passIndex,
//                                    index: materialiseIndex, order: .before)
//                )
//
//                if !historyBufferCreationFrame && !buffer.flags.contains(.persistent) {
//                    preFrameResourceCommands.append(VulkanPreFrameResourceCommand(command: .disposeResource(Resource(buffer)), passIndex: lastUsage.renderPassRecord.passIndex, index: lastUsage.commandRange.upperBound - 1, order: .after))
//                } else {
//                    if isModified { // FIXME: what if we're reading from something that the next frame will modify?
//                        let sourceMask = lastUsage.type.shaderStageMask(isDepthOrStencil: false, stages: lastUsage.stages)
//
//                        fatalError("Do we need a pipeline barrier here? We should at least make sure we set the semaphore to wait on.")
//                    }
//                }
//
//            } else if let texture = resource.texture {
//                let isDepthStencil = texture.descriptor.pixelFormat.isDepth || texture.descriptor.pixelFormat.isStencil
//
//                var isModified = false
//                var queueFamilies : QueueFamilies = []
//
//                var textureUsage : VkImageUsageFlagBits = []
//                if texture.flags.contains(.historyBuffer) {
//                    textureUsage.formUnion(VkImageUsageFlagBits(texture.descriptor.usageHint, pixelFormat: texture.descriptor.pixelFormat))
//                }
//
//                var previousUsage : ResourceUsage? = nil
//
//                for usage in usages where usage.renderPassRecord.isActive && usage.stages != .cpuBeforeRender {
//                    defer { previousUsage = usage }
//
//                    switch usage.renderPassRecord.pass.passType {
//                    case .draw:
//                        queueFamilies.formUnion(.graphics)
//                    case .compute:
//                        queueFamilies.formUnion(.compute)
//                    case .blit:
//                        queueFamilies.formUnion(.copy)
//                    case .cpu, .external:
//                        break
//                    }
//
//                    switch usage.type {
//                    case .read:
//                        textureUsage.formUnion(.sampled)
//                    case .write, .readWrite:
//                        isModified = true
//                        textureUsage.formUnion(.storage)
//                    case .inputAttachment:
//                        textureUsage.formUnion(.inputAttachment)
//                    case .unusedRenderTarget:
//                        if isDepthStencil {
//                            textureUsage.formUnion(.depthStencilAttachment)
//                        } else {
//                            textureUsage.formUnion(.colorAttachment)
//                        }
//                    case .readWriteRenderTarget, .writeOnlyRenderTarget:
//                        isModified = true
//                        if isDepthStencil {
//                            textureUsage.formUnion(.depthStencilAttachment)
//                        } else {
//                            textureUsage.formUnion(.colorAttachment)
//                        }
//                    case .inputAttachmentRenderTarget:
//                        textureUsage.formUnion(.inputAttachment)
//                    case .blitSource:
//                        textureUsage.formUnion(.transferSource)
//                    case .blitDestination:
//                        isModified = true
//                        textureUsage.formUnion(.transferDestination)
//                    case .blitSynchronisation:
//                        isModified = true
//                        textureUsage.formUnion([.transferSource, .transferDestination])
//                    case .vertexBuffer, .indexBuffer, .indirectBuffer, .constantBuffer, .sampler:
//                        fatalError()
//                    case .unusedArgumentBuffer:
//                        break
//                    }
//                }
//
//                do {
//                    let textureAlreadyExists = texture.flags.contains(.persistent) || historyBufferUseFrame
//
//                    let destinationAccessMask = firstUsage.type.accessMask(isDepthOrStencil: isDepthStencil)
//                    let destinationMask = firstUsage.type.shaderStageMask(isDepthOrStencil: isDepthStencil, stages: firstUsage.stages)
//                    let destinationLayout = firstUsage.type.imageLayout(isDepthOrStencil: isDepthStencil)
//
//                    var imageBarrierInfo = VkImageMemoryBarrier()
//                    imageBarrierInfo.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
//                    imageBarrierInfo.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
//                    imageBarrierInfo.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
//                    imageBarrierInfo.srcAccessMask = VkAccessFlags([] as VkAccessFlagBits) // since it's already been synchronised in a different way.
//                    imageBarrierInfo.dstAccessMask = VkAccessFlags(destinationAccessMask)
//                    imageBarrierInfo.oldLayout = textureAlreadyExists ? VK_IMAGE_LAYOUT_PREINITIALIZED : VK_IMAGE_LAYOUT_UNDEFINED
//                    imageBarrierInfo.newLayout = firstUsage.type.isRenderTarget ? imageBarrierInfo.oldLayout : destinationLayout
//                    imageBarrierInfo.subresourceRange = VkImageSubresourceRange(aspectMask: texture.descriptor.pixelFormat.aspectFlags, baseMipLevel: 0, levelCount: UInt32(texture.descriptor.mipmapLevelCount), baseArrayLayer: 0, layerCount: UInt32(texture.descriptor.arrayLength))
//
//                    let commandType = VulkanPreFrameResourceCommands.materialiseTexture(texture, usage: textureUsage, destinationMask: destinationMask, barrier: imageBarrierInfo)
//
//
//                    if firstUsage.renderPassRecord.pass.passType == .draw {
//                        // Materialise the texture (performing layout transitions) before we begin the Vulkan render pass.
//                        let firstPass = renderTargetDescriptors[firstUsage.renderPassRecord.passIndex]!.renderPasses.first!
//
//                        if firstUsage.type.isRenderTarget {
//                            // We're not doing a layout transition here, so set the initial layout for the render pass
//                            // to the texture's current, actual layout.
//                            let vulkanTexture = resourceMap[texture]
//                            renderTargetDescriptors[firstUsage.renderPassRecord.passIndex]!.initialLayouts[texture] = vulkanTexture.layout
//                        }
//                    }
//
//                    preFrameResourceCommands.append(
//                        VulkanPreFrameResourceCommand(command: commandType,
//                                                      passIndex: materialisePass, index: materialiseIndex, order: .before))
//                }
//
//                let needsStore = historyBufferCreationFrame || texture.flags.contains(.persistent)
//                if !needsStore || texture.flags.contains(.windowHandle) {
//                    // We need to dispose window handle textures just to make sure their texture references are removed from the resource registry.
//                    preFrameResourceCommands.append(VulkanPreFrameResourceCommand(command: .disposeResource(Resource(texture)), passIndex: lastUsage.renderPassRecord.passIndex, index: lastUsage.commandRange.upperBound - 1, order: .after))
//                }
//                if needsStore && isModified {
//                    let sourceMask = lastUsage.type.shaderStageMask(isDepthOrStencil: isDepthStencil, stages: lastUsage.stages)
//
//                    var finalLayout : VkImageLayout? = nil
//
//                    if lastUsage.type.isRenderTarget {
//                        renderTargetDescriptors[lastUsage.renderPassRecord.passIndex]!.finalLayouts[texture] = VK_IMAGE_LAYOUT_GENERAL
//                        finalLayout = VK_IMAGE_LAYOUT_GENERAL
//                    }
//
//
//                    fatalError("Do we need a pipeline barrier here? We should at least make sure we set the semaphore to wait on, and maybe a pipeline barrier is necessary as well for non render-target textures.")
//                }
//
//            }
//        }
//
//        self.preFrameResourceCommands.sort()
//        self.resourceCommands.sort()
//    }
    
}

enum VulkanResourceMemoryBarrier {
    case texture(Texture, VkImageMemoryBarrier)
    case buffer(Buffer, VkBufferMemoryBarrier)
}

struct VulkanMemoryBarrierInfo {
    var sourceMask : VkPipelineStageFlagBits
    var destinationMask : VkPipelineStageFlagBits
    var barrier : VulkanResourceMemoryBarrier
}

enum VulkanCompactedResourceCommandType {
    case signalEvent(VkEvent, afterStages: VkPipelineStageFlagBits)
    
    case waitForEvents(_ events: UnsafeBufferPointer<VkEvent?>, sourceStages: VkPipelineStageFlagBits, destinationStages: VkPipelineStageFlagBits, memoryBarriers: UnsafeBufferPointer<VkMemoryBarrier>, bufferMemoryBarriers: UnsafeBufferPointer<VkBufferMemoryBarrier>, imageMemoryBarriers: UnsafeBufferPointer<VkImageMemoryBarrier>)
    
    case pipelineBarrier(sourceStages: VkPipelineStageFlagBits, destinationStages: VkPipelineStageFlagBits, dependencyFlags: VkDependencyFlagBits, memoryBarriers: UnsafeBufferPointer<VkMemoryBarrier>, bufferMemoryBarriers: UnsafeBufferPointer<VkBufferMemoryBarrier>, imageMemoryBarriers: UnsafeBufferPointer<VkImageMemoryBarrier>)
}


#endif // canImport(Vulkan)
