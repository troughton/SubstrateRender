//
//  GPUResourceUploader.swift
//  LlamaCore
//
//  Created by Thomas Roughton on 10/01/19.
//

import FrameGraphUtilities

public final class GPUResourceUploader {
    // Useful to bypass uploading when running in GPU-less mode.
    public static var skipUpload = false
    
    static var frameGraph : FrameGraph! = nil
    private static var enqueuedBytes = 0
    private static var maxUploadSize = 128 * 1024 * 1024
    
    @usableFromInline
    final class UploadResourcePass : BlitRenderPass {
        public let name: String = "GPU Resource Upload"
        
        @usableFromInline let closure : (RawBufferSlice, _ bce: BlitCommandEncoder) -> Void
        @usableFromInline let stagingBufferLength: Int
        
        @inlinable
        init(stagingBufferLength: Int, closure: @escaping (_ stagingBuffer: RawBufferSlice, _ bce: BlitCommandEncoder) -> Void) {
            assert(stagingBufferLength > 0)
            self.stagingBufferLength = stagingBufferLength
            self.closure = closure
        }
        
        @inlinable
        public func execute(blitCommandEncoder: BlitCommandEncoder) {
            let stagingBuffer = Buffer(length: self.stagingBufferLength, storageMode: .shared, cacheMode: .writeCombined)
            let bufferSlice = stagingBuffer[stagingBuffer.range, accessType: .write]
            self.closure(bufferSlice, blitCommandEncoder)
        }
    }
    
    public static func initialise(maxUploadSize: Int = 128 * 1024 * 1024) {
        self.maxUploadSize = maxUploadSize
        self.frameGraph = FrameGraph(inflightFrameCount: 1)
    }
    
    private init() {}
    
    public static func flush() {
        self.frameGraph.execute()
        self.enqueuedBytes = 0
    }
    
    public static func addUploadPass(stagingBufferLength: Int, pass: @escaping (RawBufferSlice, _ bce: BlitCommandEncoder) -> Void) {
        if GPUResourceUploader.skipUpload {
            return
        }
        precondition(self.frameGraph != nil, "GPUResourceLoader.initialise() has not been called.")
        
        if self.enqueuedBytes + stagingBufferLength >= self.maxUploadSize {
            self.flush()
        }
        frameGraph.addPass(UploadResourcePass(stagingBufferLength: stagingBufferLength, closure: pass))
        self.enqueuedBytes += stagingBufferLength
    }
    
    public static func uploadBytes(_ bytes: UnsafeRawPointer, count: Int, to buffer: Buffer, offset: Int, onUploadCompleted: ((Buffer, UnsafeRawPointer) -> Void)? = nil) {
        assert(offset + count <= buffer.length)
        
        if buffer.storageMode == .shared || buffer.storageMode == .managed {
            buffer[offset..<(offset + count), accessType: .write].withContents {
                $0.copyMemory(from: bytes, byteCount: count)
            }
            onUploadCompleted?(buffer, bytes)
        } else {
            assert(buffer.storageMode == .private)
            self.addUploadPass(stagingBufferLength: count, pass: { slice, bce in
                slice.withContents {
                    $0.copyMemory(from: bytes, byteCount: count)
                }
                onUploadCompleted?(buffer, bytes)
            })
        }
    }
    
    public static func replaceTextureRegion(_ region: Region, mipmapLevel: Int, in texture: Texture, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int, onUploadCompleted: ((Texture, UnsafeRawPointer) -> Void)? = nil) {
        self.replaceTextureRegion(region, mipmapLevel: mipmapLevel, slice: 0, in: texture, withBytes: bytes, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerRow * texture.height)
    }
        
    public static func replaceTextureRegion(_ region: Region, mipmapLevel: Int, slice: Int, in texture: Texture, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int, bytesPerImage: Int, onUploadCompleted: ((Texture, UnsafeRawPointer) -> Void)? = nil) {
        if texture.storageMode == .shared || texture.storageMode == .managed {
            texture.replace(region: region, mipmapLevel: mipmapLevel, slice: slice, withBytes: bytes, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
            onUploadCompleted?(texture, bytes)
        } else {
            assert(texture.storageMode == .private)
            
            self.addUploadPass(stagingBufferLength: bytesPerImage, pass: { bufferSlice, bce in
                bufferSlice.withContents {
                    $0.copyMemory(from: bytes, byteCount: bytesPerImage)
                }
                bce.copy(from: bufferSlice.buffer, sourceOffset: bufferSlice.range.lowerBound, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerImage, sourceSize: region.size, to: texture, destinationSlice: slice, destinationLevel: mipmapLevel, destinationOrigin: region.origin)
                
                onUploadCompleted?(texture, bytes)
            })
        }
    }
}
