//
//  Resources.swift
//  RenderAPI
//
//  Created by Joseph Bennett on 18/12/17.
//

import FrameGraphUtilities

public enum ResourceType : UInt8 {
    case buffer = 1
    case texture
    case sampler
    case threadgroupMemory
    case argumentBuffer
    case argumentBufferArray
    case imageblockData
    case imageblock
}

/*!
 @abstract Points at which a fence may be waited on or signaled.
 @constant RenderStageVertex   All vertex work prior to rasterization has completed.
 @constant RenderStageFragment All rendering work has completed.
 */
public struct RenderStages : OptionSet, Hashable {
    
    public let rawValue : UInt
    
    @inlinable
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
    
    public static var vertex: RenderStages = RenderStages(rawValue: 1 << 0)
    public static var fragment: RenderStages = RenderStages(rawValue: 1 << 1)
    
    public static var compute: RenderStages = RenderStages(rawValue: 1 << 5)
    public static var blit: RenderStages = RenderStages(rawValue: 1 << 6)
    
    public static var cpuBeforeRender: RenderStages = RenderStages(rawValue: 1 << 7)
    
    public var first : RenderStages {
        switch (self.contains(.vertex), self.contains(.fragment)) {
        case (true, _):
            return .vertex
        case (false, true):
            return .fragment
        default:
            return self
        }
    }
    
    public var last : RenderStages {
        switch (self.contains(.vertex), self.contains(.fragment)) {
        case (_, true):
            return .fragment
        case (true, false):
            return .vertex
        default:
            return self
        }
    }
    
    public var hashValue: Int {
        return Int(bitPattern: self.rawValue)
    }
}

public struct ResourceFlags : OptionSet {
    public let rawValue: UInt8
    
    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
    
    public static let persistent = ResourceFlags(rawValue: 1 << 0)
    public static let windowHandle = ResourceFlags(rawValue: 1 << 1)
    public static let historyBuffer = ResourceFlags(rawValue: 1 << 2)
    public static let externalOwnership = ResourceFlags(rawValue: 1 << 3)
    public static let immutableOnceInitialised = ResourceFlags(rawValue: 1 << 4)
}

extension ResourceFlags {
    /// If this resource is a view into another resource.
    @usableFromInline
    static let resourceView = ResourceFlags(rawValue: 1 << 5)
}

public struct ResourceStateFlags : OptionSet {
    public let rawValue: UInt16
    
    @inlinable
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
    
    public static let initialised = ResourceStateFlags(rawValue: 1 << 0)
}

public enum ResourceAccessType {
    case read
    case write
    case readWrite
}

public protocol ResourceProtocol : Hashable {
    
    init(handle: Handle)
    func dispose()
    
    var handle : Handle { get }
    var stateFlags : ResourceStateFlags { get nonmutating set }
    
    var usages : ResourceUsagesList { get }
    
    var label : String? { get nonmutating set }
    var storageMode : StorageMode { get }
    
    var readWaitFrame : UInt64 { get nonmutating set }
    var writeWaitFrame : UInt64 { get nonmutating set }
}

extension ResourceProtocol {
    @inlinable
    public static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs.handle == rhs.handle
    }
}

public struct Resource : ResourceProtocol, Hashable {
    public let handle : Handle
    
    @inlinable
    public init<R : ResourceProtocol>(_ resource: R) {
        self.handle = resource.handle
    }
    
    @inlinable
    public init(handle: Handle) {
        assert(handle == .max || ResourceType(rawValue: ResourceType.RawValue(truncatingIfNeeded: handle >> 48)) != nil)
        
        self.handle = handle
    }
    
    @inlinable
    public var buffer : Buffer? {
        if self.type == .buffer {
            return Buffer(handle: self.handle)
        } else {
            return nil
        }
    }
    
    @inlinable
    public var texture : Texture? {
        if self.type == .texture {
            return Texture(handle: self.handle)
        } else {
            return nil
        }
    }
    
    @inlinable
    public var argumentBuffer : _ArgumentBuffer? {
        if self.type == .argumentBuffer {
            return _ArgumentBuffer(handle: self.handle)
        } else {
            return nil
        }
    }
    
    @inlinable
    public var argumentBufferArray : _ArgumentBufferArray? {
        if self.type == .argumentBufferArray {
            return _ArgumentBufferArray(handle: self.handle)
        } else {
            return nil
        }
    }
    
    public static let invalidResource = Resource(handle: .max)
}

extension Resource : CustomHashable {
    public var customHashValue : Int {
        return self.hashValue
    }
}

extension ResourceProtocol {
    public typealias Handle = UInt64
    
    @inlinable
    public var type : ResourceType {
        return ResourceType(rawValue: ResourceType.RawValue(truncatingIfNeeded: self.handle >> 48))!
    }
    
    @inlinable
    public var index : Int {
        return Int(truncatingIfNeeded: self.handle & 0x1FFFFFFF) // The lower 29 bits contain the index
    }
    
    @inlinable
    public var flags : ResourceFlags {
        return ResourceFlags(rawValue: ResourceFlags.RawValue(truncatingIfNeeded: (self.handle >> 32) & 0xFFFF))
    }
    
    @inlinable
    public var _usesPersistentRegistry : Bool {
        if self.flags.contains(.persistent) || self.flags.contains(.historyBuffer) {
            return true
        } else {
            return false
        }
    }
    
    @inlinable
    public func markAsInitialised() {
        self.stateFlags.formUnion(.initialised)
    }
    
    @inlinable
    public func discardContents() {
        self.stateFlags.remove(.initialised)
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            switch self.type {
            case .buffer:
                return Buffer(handle: self.handle).stateFlags
            case .texture:
                return Texture(handle: self.handle).stateFlags
            case .argumentBuffer:
                return _ArgumentBuffer(handle: self.handle).stateFlags
            case .argumentBufferArray:
                return _ArgumentBufferArray(handle: self.handle).stateFlags
            default:
                fatalError()
            }
        }
        nonmutating set {
            switch self.type {
            case .buffer:
                Buffer(handle: self.handle).stateFlags = newValue
            case .texture:
                Texture(handle: self.handle).stateFlags = newValue
            case .argumentBuffer:
                _ArgumentBuffer(handle: self.handle).stateFlags = newValue
            case .argumentBufferArray:
                _ArgumentBufferArray(handle: self.handle).stateFlags = newValue
            default:
                fatalError()
            }
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        get {
            switch self.type {
            case .buffer:
                return Buffer(handle: self.handle).storageMode
            case .texture:
                return Texture(handle: self.handle).storageMode
            case .argumentBuffer:
                return _ArgumentBuffer(handle: self.handle).storageMode
            case .argumentBufferArray:
                return _ArgumentBufferArray(handle: self.handle).storageMode
            default:
                fatalError()
            }
        }
    }
    
    @inlinable
    public var label: String? {
        get {
            switch self.type {
            case .buffer:
                return Buffer(handle: self.handle).label
            case .texture:
                return Texture(handle: self.handle).label
            case .argumentBuffer:
                return _ArgumentBuffer(handle: self.handle).label
            case .argumentBufferArray:
                return _ArgumentBufferArray(handle: self.handle).label
            default:
                fatalError()
            }
        }
        nonmutating set {
            switch self.type {
            case .buffer:
                Buffer(handle: self.handle).label = newValue
            case .texture:
                Texture(handle: self.handle).label = newValue
            case .argumentBuffer:
                _ArgumentBuffer(handle: self.handle).label = newValue
            case .argumentBufferArray:
                _ArgumentBufferArray(handle: self.handle).label = newValue
            default:
                fatalError()
            }
        }
    }
    
    @inlinable
    public var readWaitFrame: UInt64 {
        get {
            switch self.type {
            case .buffer:
                return Buffer(handle: self.handle).readWaitFrame
            case .texture:
                return Texture(handle: self.handle).readWaitFrame
            default:
                return 0
            }
        }
        nonmutating set {
            switch self.type {
            case .buffer:
                Buffer(handle: self.handle).readWaitFrame = newValue
            case .texture:
                Texture(handle: self.handle).readWaitFrame = newValue
            default:
                break
            }
        }
    }
    
    @inlinable
    public var writeWaitFrame: UInt64 {
        get {
            switch self.type {
            case .buffer:
                return Buffer(handle: self.handle).writeWaitFrame
            case .texture:
                return Texture(handle: self.handle).writeWaitFrame
            default:
                return 0
            }
        }
        nonmutating set {
            switch self.type {
            case .buffer:
                Buffer(handle: self.handle).writeWaitFrame = newValue
            case .texture:
                Texture(handle: self.handle).writeWaitFrame = newValue
            default:
                break
            }
        }
    }
    
    @inlinable
    public var usages: ResourceUsagesList {
        get {
            switch self.type {
            case .buffer:
                return Buffer(handle: self.handle).usages
            case .texture:
                return Texture(handle: self.handle).usages
            case .argumentBuffer:
                return _ArgumentBuffer(handle: self.handle).usages
            default:
                return ResourceUsagesList()
            }
        }
    }
    
    @inlinable
    internal var usagesPointer: UnsafeMutablePointer<ResourceUsagesList> {
        get {
            switch self.type {
            case .buffer:
                return Buffer(handle: self.handle).usagesPointer
            case .texture:
                return Texture(handle: self.handle).usagesPointer
            case .argumentBuffer:
                return _ArgumentBuffer(handle: self.handle).usagesPointer
            default:
                fatalError()
            }
        }
    }
    
    @inlinable
    public var baseResource: Resource? {
        get {
            switch self.type {
            case .texture:
                return Texture(handle: self.handle).baseResource
            default:
                return nil
            }
        }
    }
    
    @inlinable
    public func dispose() {
        switch self.type {
        case .buffer:
            Buffer(handle: self.handle).dispose()
        case .texture:
            Texture(handle: self.handle).dispose()
        case .argumentBuffer:
            _ArgumentBuffer(handle: self.handle).dispose()
        case .argumentBufferArray:
            _ArgumentBufferArray(handle: self.handle).dispose()
        default:
            break
        }
    }
    
    @inlinable
    public var isTextureView : Bool {
        return self.flags.contains(.resourceView)
    }
}

public struct Buffer : ResourceProtocol {
    public struct TextureViewDescriptor {
        public var descriptor : TextureDescriptor
        public var offset : Int
        public var bytesPerRow : Int
        
        @inlinable
        public init(descriptor: TextureDescriptor, offset: Int, bytesPerRow: Int) {
            self.descriptor = descriptor
            self.offset = offset
            self.bytesPerRow = bytesPerRow
        }
    }
    
    public let handle : Handle
    
    @inlinable
    public init(handle: Handle) {
        assert(handle == .max || Resource(handle: handle).type == .buffer)
        self.handle = handle
    }
    
    @inlinable
    public init(length: Int, storageMode: StorageMode = .managed, cacheMode: CPUCacheMode = .defaultCache, usage: BufferUsage = .unknown, bytes: UnsafeRawPointer? = nil, flags: ResourceFlags = []) {
        self.init(descriptor: BufferDescriptor(length: length, storageMode: storageMode, cacheMode: cacheMode, usage: usage), bytes: bytes, flags: flags)
    }
    
    @inlinable
    public init(descriptor: BufferDescriptor, flags: ResourceFlags = []) {
        let index : UInt64
        if flags.contains(.persistent) || flags.contains(.historyBuffer) {
            index = PersistentBufferRegistry.instance.allocate(descriptor: descriptor, flags: flags)
        } else {
            index = TransientBufferRegistry.instance.allocate(descriptor: descriptor, flags: flags)
        }
        
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.buffer.rawValue) << 48)
        
        if self.flags.contains(.persistent) {
            assert(!descriptor.usageHint.isEmpty, "Persistent resources must explicitly specify their usage.")
            RenderBackend.materialisePersistentBuffer(self)
        }
    }
    
    @inlinable
    public init(descriptor: BufferDescriptor, bytes: UnsafeRawPointer?, flags: ResourceFlags = []) {
        self.init(descriptor: descriptor, flags: flags)
        
        if let bytes = bytes {
            assert(self.descriptor.storageMode != .private)
            self[0..<self.descriptor.length, accessType: .write].withContents { $0.copyMemory(from: bytes, byteCount: self.descriptor.length) }
        }
    }
    
    @inlinable
    public subscript(range: Range<Int>) -> RawBufferSlice {
        return self[range, accessType: .readWrite]
    }
    
    @inlinable
    public subscript(range: Range<Int>, accessType accessType: ResourceAccessType) -> RawBufferSlice {
        self.waitForCPUAccess(accessType: accessType)
        return RawBufferSlice(buffer: self, range: range, accessType: accessType)
    }
    
    public func withDeferredSlice(range: Range<Int>, perform: @escaping (RawBufferSlice) -> Void) {
        if self.flags.contains(.persistent) {
            perform(self[range])
        } else {
            self._deferredSliceActions.append(DeferredRawBufferSlice(range: range, closure: perform))
        }
    }
    
    @inlinable
    public subscript<T>(byteRange range: Range<Int>, as type: T.Type) -> BufferSlice<T> {
        return self[byteRange: range, as: type, accessType: .readWrite]
    }
    
    @inlinable
    public subscript<T>(byteRange range: Range<Int>, as type: T.Type, accessType accessType: ResourceAccessType) -> BufferSlice<T> {
        self.waitForCPUAccess(accessType: accessType)
        return BufferSlice(buffer: self, range: range, accessType: accessType)
    }
    
    public func withDeferredSlice<T>(byteRange range: Range<Int>, perform: @escaping (BufferSlice<T>) -> Void) {
        if self.flags.contains(.persistent) {
            perform(self[byteRange: range, as: T.self])
        } else {
            self._deferredSliceActions.append(DeferredTypedBufferSlice(range: range, closure: perform))
        }
    }
    
    @inlinable
    public func fillWhenMaterialised<C : Collection>(from source: C) {
        let requiredCapacity = source.count * MemoryLayout<C.Element>.stride
        assert(self.length >= requiredCapacity)
        
        self.withDeferredSlice(byteRange: 0..<requiredCapacity) { (slice: BufferSlice<C.Element>) -> Void in
            slice.withContents { (contents: UnsafeMutablePointer<C.Element>) in
                _ = UnsafeMutableBufferPointer(start: contents, count: source.count).initialize(from: source)
            }
        }
    }
    
    public func onMaterialiseGPUBacking(perform: @escaping (Buffer) -> Void) {
        if self.flags.contains(.persistent) {
            perform(self)
        } else {
            self._deferredSliceActions.append(EmptyBufferSlice(closure: perform))
        }
    }
    
    public func applyDeferredSliceActions() {
        // TODO: Add support for deferred slice actions to persistent resources. 
        guard !self.flags.contains(.historyBuffer) else {
            return
        }
        
        for action in self._deferredSliceActions {
            action.apply(self)
        }
        self._deferredSliceActions.removeAll(keepingCapacity: true)
    }
    
    @inlinable
    public var length : Int {
        return self.descriptor.length
    }
    
    @inlinable
    public var range : Range<Int> {
        return 0..<self.descriptor.length
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            if self.flags.intersection([.historyBuffer, .persistent]) == [] {
                return []
            }
            
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
            return PersistentBufferRegistry.instance.chunks[chunkIndex].stateFlags[indexInChunk]
        }
        nonmutating set {
            if self.flags.intersection([.historyBuffer, .persistent]) == [] { return }
            
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
            PersistentBufferRegistry.instance.chunks[chunkIndex].stateFlags[indexInChunk] = newValue
        }
    }
    
    @inlinable
    public var descriptor : BufferDescriptor {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentBufferRegistry.instance.chunks[chunkIndex].descriptors[indexInChunk]
            } else {
                return TransientBufferRegistry.instance.descriptors[index]
            }
        }
        nonmutating set {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
                PersistentBufferRegistry.instance.chunks[chunkIndex].descriptors[indexInChunk] = newValue
            } else {
                TransientBufferRegistry.instance.descriptors[index] = newValue
            }
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return self.descriptor.storageMode
    }
    
    @inlinable
    public var label : String? {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentBufferRegistry.instance.chunks[chunkIndex].labels[indexInChunk]
            } else {
                return TransientBufferRegistry.instance.labels[index]
            }
        }
        nonmutating set {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
                PersistentBufferRegistry.instance.chunks[chunkIndex].labels[indexInChunk] = newValue
            } else {
                TransientBufferRegistry.instance.labels[index] = newValue
            }
        }
    }
    
    @inlinable
    public var _deferredSliceActions : [DeferredBufferSlice] {
        get {
            assert(!self._usesPersistentRegistry)
            
            return TransientBufferRegistry.instance.deferredSliceActions[self.index]
    
        }
        nonmutating set {
            assert(!self._usesPersistentRegistry)
            
            TransientBufferRegistry.instance.deferredSliceActions[self.index] = newValue
        }
    }
    
    @inlinable
    public var readWaitFrame: UInt64 {
        get {
            guard self.flags.contains(.persistent) else { return 0 }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
            return PersistentBufferRegistry.instance.chunks[chunkIndex].readWaitFrames[indexInChunk]
        }
        nonmutating set {
            guard self.flags.contains(.persistent) else { return }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
            PersistentBufferRegistry.instance.chunks[chunkIndex].readWaitFrames[indexInChunk] = newValue
        }
    }
    
    @inlinable
    public var writeWaitFrame: UInt64 {
        get {
            guard self.flags.contains(.persistent) else { return 0 }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
            return PersistentBufferRegistry.instance.chunks[chunkIndex].writeWaitFrames[indexInChunk]
        }
        nonmutating set {
            guard self.flags.contains(.persistent) else { return }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
            PersistentBufferRegistry.instance.chunks[chunkIndex].writeWaitFrames[indexInChunk] = newValue
        }
    }
    
    @inlinable
    public func waitForCPUAccess(accessType: ResourceAccessType) {
        guard self.flags.contains(.persistent) else { return }
        let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
        
        let readWaitFrame = PersistentBufferRegistry.instance.chunks[chunkIndex].readWaitFrames[indexInChunk]
        let writeWaitFrame = PersistentBufferRegistry.instance.chunks[chunkIndex].writeWaitFrames[indexInChunk]
        switch accessType {
        case .read:
            FrameCompletion.waitForFrame(readWaitFrame)
        case .write:
            FrameCompletion.waitForFrame(writeWaitFrame)
        case .readWrite:
            FrameCompletion.waitForFrame(max(readWaitFrame, writeWaitFrame))
        }
    }
    
    @inlinable
    public var usages : ResourceUsagesList {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentBufferRegistry.instance.chunks[chunkIndex].usages[indexInChunk]
            } else {
                return TransientBufferRegistry.instance.usages[index]
            }
        }
    }
    
    @inlinable
    var usagesPointer : UnsafeMutablePointer<ResourceUsagesList> {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentBufferRegistry.instance.chunks[chunkIndex].usages.advanced(by: indexInChunk)
            } else {
                return TransientBufferRegistry.instance.usages.advanced(by: index)
            }
        }
    }
    
    @inlinable
    public func dispose(atEndOfFrame: Bool = true) {
        guard self._usesPersistentRegistry else {
            return
        }
        PersistentBufferRegistry.instance.dispose(self, atEndOfFrame: atEndOfFrame)
    }
}

public struct Texture : ResourceProtocol {
    public struct TextureViewDescriptor {
        public var pixelFormat: PixelFormat
        public var textureType: TextureType
        public var levels: Range<Int>
        public var slices: Range<Int>
        
        @inlinable
        public init(pixelFormat: PixelFormat, textureType: TextureType, levels: Range<Int> = -1..<0, slices: Range<Int> = -1..<0) {
            self.pixelFormat = pixelFormat
            self.textureType = textureType
            self.levels = levels
            self.slices = slices
        }
    }
    
    public let handle : Handle
    
    @inlinable
    public init(handle: Handle) {
        assert(handle == .max || Resource(handle: handle).type == .texture)
        self.handle = handle
    }
    
    @inlinable
    public init(descriptor: TextureDescriptor, flags: ResourceFlags = []) {
        let index : UInt64
        if flags.contains(.persistent) || flags.contains(.historyBuffer) {
            index = PersistentTextureRegistry.instance.allocate(descriptor: descriptor, flags: flags)
        } else {
            index = TransientTextureRegistry.instance.allocate(descriptor: descriptor, flags: flags)
        }
        
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.texture.rawValue) << 48)
        
        if self.flags.contains(.persistent) {
            assert(!descriptor.usageHint.isEmpty, "Persistent resources must explicitly specify their usage.")
            RenderBackend.materialisePersistentTexture(self)
        }
    }
    
    @inlinable
    public init(descriptor: TextureDescriptor, externalResource: Any, flags: ResourceFlags = [.persistent, .externalOwnership]) {
        let index : UInt64
        if flags.contains(.persistent) || flags.contains(.historyBuffer) {
            index = PersistentTextureRegistry.instance.allocate(descriptor: descriptor, flags: flags)
        } else {
            index = TransientTextureRegistry.instance.allocate(descriptor: descriptor, flags: flags)
        }
        
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.texture.rawValue) << 48)
        
        if self.flags.contains(.persistent) {
            assert(!descriptor.usageHint.isEmpty, "Persistent resources must explicitly specify their usage.")
        }
        RenderBackend.registerExternalResource(Resource(self), backingResource: externalResource)
    }
    
    @inlinable
    public init(viewOf base: Texture, descriptor: TextureViewDescriptor) {
        let flags : ResourceFlags = .resourceView
        
        let index = TransientTextureRegistry.instance.allocate(descriptor: descriptor, baseResource: base)
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.texture.rawValue) << 48)
    }
    
    @inlinable
    public init(viewOf base: Buffer, descriptor: Buffer.TextureViewDescriptor) {
        let flags : ResourceFlags = .resourceView
    
        let index = TransientTextureRegistry.instance.allocate(descriptor: descriptor, baseResource: base)
        self.handle = index | (UInt64(flags.rawValue) << 32) | (UInt64(ResourceType.texture.rawValue) << 48)
    }
    
    @inlinable
    public init(windowId: Int, descriptor: TextureDescriptor, isMinimised: Bool, nativeWindow: Any) {
        self.init(descriptor: descriptor, flags: isMinimised ? [] : .windowHandle)
        
        if !isMinimised {
            RenderBackend.registerWindowTexture(texture: self, context: nativeWindow)
        }
    }
    
    @inlinable
    public func copyBytes(to bytes: UnsafeMutableRawPointer, bytesPerRow: Int, region: Region, mipmapLevel: Int) {
        self.waitForCPUAccess(accessType: .read)
        RenderBackend.copyTextureBytes(from: self, to: bytes, bytesPerRow: bytesPerRow, region: region, mipmapLevel: mipmapLevel)
    }
    
    @inlinable
    public func replace(region: Region, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) {
        self.waitForCPUAccess(accessType: .write)
        
        RenderBackend.replaceTextureRegion(texture: self, region: region, mipmapLevel: mipmapLevel, withBytes: bytes, bytesPerRow: bytesPerRow)
    }
    
    @inlinable
    public func replace(region: Region, mipmapLevel: Int, slice: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int, bytesPerImage: Int) {
        self.waitForCPUAccess(accessType: .write)
        
        RenderBackend.replaceTextureRegion(texture: self, region: region, mipmapLevel: mipmapLevel, slice: slice, withBytes: bytes, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
    }
    
    @inlinable
    public var flags : ResourceFlags {
        return ResourceFlags(rawValue: ResourceFlags.RawValue(truncatingIfNeeded: (self.handle >> 32) & 0xFFFF))
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            if self.flags.intersection([.historyBuffer, .persistent]) == [] {
                return []
            }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
            return PersistentTextureRegistry.instance.chunks[chunkIndex].stateFlags[indexInChunk]
        }
        nonmutating set {
            assert(self.flags.intersection([.historyBuffer, .persistent]) != [], "State flags can only be set on persistent resources.")
            
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
            PersistentTextureRegistry.instance.chunks[chunkIndex].stateFlags[indexInChunk] = newValue
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return self.descriptor.storageMode
    }
    
    @inlinable
    public var descriptor : TextureDescriptor {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
                return PersistentTextureRegistry.instance.chunks[chunkIndex].descriptors[indexInChunk]
            } else {
                return TransientTextureRegistry.instance.descriptors[index]
            }
        }
        nonmutating set {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
                PersistentTextureRegistry.instance.chunks[chunkIndex].descriptors[indexInChunk] = newValue
            } else {
                TransientTextureRegistry.instance.descriptors[index] = newValue
            }
        }
    }
    
    @inlinable
    public var label : String? {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
                return PersistentTextureRegistry.instance.chunks[chunkIndex].labels[indexInChunk]
            } else {
                return TransientTextureRegistry.instance.labels[index]
            }
        }
        nonmutating set {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
                PersistentTextureRegistry.instance.chunks[chunkIndex].labels[indexInChunk] = newValue
            } else {
                TransientTextureRegistry.instance.labels[index] = newValue
            }
        }
    }
    
    @inlinable
    public var readWaitFrame: UInt64 {
        get {
            guard self.flags.contains(.persistent) else { return 0 }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
            return PersistentTextureRegistry.instance.chunks[chunkIndex].readWaitFrames[indexInChunk]
        }
        nonmutating set {
            guard self.flags.contains(.persistent) else { return }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
            PersistentTextureRegistry.instance.chunks[chunkIndex].readWaitFrames[indexInChunk] = newValue
        }
    }
    
    @inlinable
    public var writeWaitFrame: UInt64 {
        get {
            guard self.flags.contains(.persistent) else { return 0 }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
            return PersistentTextureRegistry.instance.chunks[chunkIndex].writeWaitFrames[indexInChunk]
        }
        nonmutating set {
            guard self.flags.contains(.persistent) else { return }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
            PersistentTextureRegistry.instance.chunks[chunkIndex].writeWaitFrames[indexInChunk] = newValue
        }
    }
    
    @inlinable
    public func waitForCPUAccess(accessType: ResourceAccessType) {
        guard self.flags.contains(.persistent) else { return }

        let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
        let readWaitFrame = PersistentTextureRegistry.instance.chunks[chunkIndex].readWaitFrames[indexInChunk]
        let writeWaitFrame = PersistentTextureRegistry.instance.chunks[chunkIndex].writeWaitFrames[indexInChunk]
        switch accessType {
        case .read:
            FrameCompletion.waitForFrame(readWaitFrame)
        case .write:
            FrameCompletion.waitForFrame(writeWaitFrame)
        case .readWrite:
            FrameCompletion.waitForFrame(max(readWaitFrame, writeWaitFrame))
        }
    }
    
    @inlinable
    public var size : Size {
        return Size(width: self.descriptor.width, height: self.descriptor.height, depth: self.descriptor.depth)
    }
    
    @inlinable
    public var width : Int {
        return self.descriptor.width
    }
    
    @inlinable
    public var height : Int {
        return self.descriptor.height
    }
    
    @inlinable
    public var depth : Int {
        return self.descriptor.depth
    }
    
    @inlinable
    public var usages : ResourceUsagesList {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
                return PersistentTextureRegistry.instance.chunks[chunkIndex].usages[indexInChunk]
            } else {
                return self.baseResource?.usages ?? TransientTextureRegistry.instance.usages[index]
            }
        }
    }
    
    @inlinable
    var usagesPointer: UnsafeMutablePointer<ResourceUsagesList> {
        get {
            let index = self.index
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentTextureRegistry.Chunk.itemsPerChunk)
                return PersistentTextureRegistry.instance.chunks[chunkIndex].usages.advanced(by: indexInChunk)
            } else {
                return self.baseResource?.usagesPointer ?? TransientTextureRegistry.instance.usages.advanced(by: index)
            }
        }
    }
    
    @inlinable
    public var baseResource : Resource? {
        get {
            let index = self.index
            if !self.isTextureView {
                return nil
            } else {
                return TransientTextureRegistry.instance.baseResources[index]
            }
        }
    }
    
    @inlinable
    public var textureViewBaseInfo : TextureViewBaseInfo? {
        let index = self.index
        if !self.isTextureView {
            return nil
        } else {
            return TransientTextureRegistry.instance.textureViewInfos[index]
        }
    }
    
    @inlinable
    public func dispose() {
        guard self._usesPersistentRegistry else {
            return
        }
        PersistentTextureRegistry.instance.dispose(self)
    }
    
    public static let invalid = Texture(descriptor: TextureDescriptor(texture2DWithFormat: .r32Float, width: 1, height: 1, mipmapped: false, usageHint: .shaderRead), flags: .persistent)
    
}

public protocol DeferredBufferSlice {
    func apply(_ buffer: Buffer)
}

final class DeferredRawBufferSlice : DeferredBufferSlice {
    let range : Range<Int>
    let closure : (RawBufferSlice) -> Void
    
    init(range: Range<Int>, closure: @escaping (RawBufferSlice) -> Void) {
        self.range = range
        self.closure = closure
    }
    
    func apply(_ buffer: Buffer) {
        self.closure(buffer[self.range])
    }
}

final class DeferredTypedBufferSlice<T> : DeferredBufferSlice {
    let range : Range<Int>
    let closure : (BufferSlice<T>) -> Void
    
    init(range: Range<Int>, closure: @escaping (BufferSlice<T>) -> Void) {
        self.range = range
        self.closure = closure
    }
    
    func apply(_ buffer: Buffer) {
        self.closure(buffer[byteRange: self.range, as: T.self])
    }
}

final class EmptyBufferSlice : DeferredBufferSlice {
    let closure : (Buffer) -> Void
    
    init(closure: @escaping (Buffer) -> Void) {
        self.closure = closure
    }
    
    func apply(_ buffer: Buffer) {
        self.closure(buffer)
    }
}

public final class RawBufferSlice {
    public let buffer : Buffer
    @usableFromInline var _range : Range<Int>
    
    @usableFromInline
    let contents : UnsafeMutableRawPointer
    
    @usableFromInline
    let accessType : ResourceAccessType
    
    var writtenToGPU = false
    
    @inlinable
    internal init(buffer: Buffer, range: Range<Int>, accessType: ResourceAccessType) {
        self.buffer = buffer
        self._range = range
        self.contents = RenderBackend.bufferContents(for: self.buffer, range: self._range)
        self.accessType = accessType
    }
    
    @inlinable
    public func withContents<A>(_ perform: (UnsafeMutableRawPointer) throws -> A) rethrows -> A {
        return try perform(self.contents)
    }
    
    @inlinable
    public var range : Range<Int> {
        return self._range
    }
    
    public func setBytesWrittenCount(_ bytesAccessed: Int) {
        assert(bytesAccessed <= self.range.count)
        self._range = self.range.lowerBound..<(self.range.lowerBound + bytesAccessed)
        self.writtenToGPU = false
    }
    
    public func forceFlush() {
        if self.accessType == .read { return }
        
        RenderBackend.buffer(self.buffer, didModifyRange: self.range)
        self.writtenToGPU = true
        
        self.buffer.stateFlags.formUnion(.initialised)
    }
    
    deinit {
        if !self.writtenToGPU {
            self.forceFlush()
        }
    }
}

public final class BufferSlice<T> {
    public let buffer : Buffer
    @usableFromInline var _range : Range<Int>
    @usableFromInline
    let contents : UnsafeMutablePointer<T>
    @usableFromInline
    let accessType : ResourceAccessType
    
    var writtenToGPU = false
    
    @inlinable
    internal init(buffer: Buffer, range: Range<Int>, accessType: ResourceAccessType) {
        self.buffer = buffer
        self._range = range
        self.contents = RenderBackend.bufferContents(for: self.buffer, range: self._range).bindMemory(to: T.self, capacity: range.count)
        self.accessType = accessType
    }
    
    @inlinable
    public subscript(index: Int) -> T {
        get {
            assert(self.accessType != .write)
            return self.contents[index]
        }
        set {
            assert(self.accessType != .read)
            self.contents[index] = newValue
        }
    }
    
    @inlinable
    public var range : Range<Int> {
        return self._range
    }
    
    @inlinable
    public func withContents<A>(_ perform: (UnsafeMutablePointer<T>) throws -> A) rethrows -> A {
        return try perform(self.contents)
    }
    
    public func setElementsWrittenCount(_ elementsAccessed: Int) {
        assert(self.accessType != .read)
        
        let bytesAccessed = elementsAccessed * MemoryLayout<T>.stride
        assert(bytesAccessed <= self.range.count)
        self._range = self.range.lowerBound..<(self.range.lowerBound + bytesAccessed)
        self.writtenToGPU = false
    }
    
    public func forceFlush() {
        if self.accessType == .read { return }
        
        RenderBackend.buffer(self.buffer, didModifyRange: self.range)
        self.writtenToGPU = true
        
        self.buffer.stateFlags.formUnion(.initialised)
    }
    
    deinit {
        if !self.writtenToGPU {
            self.forceFlush()
        }
    }
}