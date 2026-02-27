//
//  RuntimeMetalEffect.swift
//  Hypnograph
//
//  Generic runtime-compiled Metal effect loaded from Application Support assets.
//

import Foundation
import CoreImage
import CoreMedia
import Metal

private struct RuntimeBufferMemberLayout {
    var name: String
    var offset: Int
    var dataType: MTLDataType
    var size: Int
}

public final class RuntimeMetalEffect: Effect {
    public static var parameterSpecs: [String: ParameterSpec] { [:] }

    public var name: String { definition.name }
    public var requiredLookback: Int { definition.requiredLookback }

    private let definition: RuntimeMetalEffectDefinition
    private var parameterValues: [String: AnyCodableValue]

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var pipelineState: MTLComputePipelineState?
    private var parameterBufferLength: Int = 0
    private var parameterBufferMembers: [RuntimeBufferMemberLayout] = []
    private var runtimeWarning: String?

    public required init?(params: [String: AnyCodableValue]?) {
        return nil
    }

    public init?(definition: RuntimeMetalEffectDefinition, params: [String: AnyCodableValue]?) {
        self.definition = definition

        var mergedValues = definition.allParameterDefaults
        for (key, value) in (params ?? [:]) {
            mergedValues[key] = value
        }
        self.parameterValues = mergedValues

        let device = SharedRenderer.metalDevice ?? MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        if let device {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext(options: [.cacheIntermediates: false])
        }

        guard device != nil, commandQueue != nil else {
            runtimeWarning = "Metal device unavailable for runtime effect '\(definition.uuid)'."
            print("⚠️ RuntimeMetalEffect: \(runtimeWarning!)")
            return nil
        }

        if !compilePipeline() {
            return nil
        }
    }

    public func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        guard let device,
              let commandQueue,
              let pipelineState else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        guard let currentTexture = makeTexture(from: image, width: width, height: height) else {
            return image
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            return image
        }

        var boundTextures: [Int: MTLTexture] = [:]
        for binding in definition.bindings.inputTextures {
            switch binding.source {
            case .currentFrame:
                boundTextures[binding.argumentIndex] = currentTexture

            case .historyFrame:
                let offset = resolvedHistoryOffset(for: binding)
                let historyImage = context.frameBuffer.previousFrame(offset: offset) ?? image
                guard let historyTexture = makeTexture(from: historyImage, width: width, height: height) else {
                    return image
                }
                boundTextures[binding.argumentIndex] = historyTexture
            }
        }
        boundTextures[definition.bindings.outputTextureIndex] = outputTexture

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return image
        }

        encoder.setComputePipelineState(pipelineState)

        for index in boundTextures.keys.sorted() {
            encoder.setTexture(boundTextures[index], index: index)
        }

        if let parameterBufferIndex = definition.bindings.parameterBufferIndex {
            let length = max(parameterBufferLength, 1)
            var parameterBytes = Data(count: length)
            fillParameterBuffer(
                data: &parameterBytes,
                width: width,
                height: height,
                frameIndex: context.frameIndex,
                time: context.time
            )
            parameterBytes.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                encoder.setBytes(baseAddress, length: parameterBytes.count, index: parameterBufferIndex)
            }
        }

        let threadWidth = pipelineState.threadExecutionWidth
        let threadHeight = max(1, pipelineState.maxTotalThreadsPerThreadgroup / max(threadWidth, 1))
        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadWidth - 1) / threadWidth,
            height: (height + threadHeight - 1) / threadHeight,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard let outputImage = CIImage(mtlTexture: outputTexture, options: [.colorSpace: colorSpace]) else {
            return image
        }
        return outputImage
    }

    public func reset() {
        // Runtime effect currently has no persistent per-instance surfaces.
    }

    public func copy() -> Effect {
        RuntimeMetalEffect(definition: definition, params: parameterValues) ?? self
    }

    // MARK: - Pipeline

    private func compilePipeline() -> Bool {
        guard let device else { return false }

        do {
            let library = try device.makeLibrary(source: definition.sourceCode, options: nil)
            guard let function = library.makeFunction(name: RuntimeMetalEffectLibrary.defaultFunctionName) else {
                runtimeWarning = "Function '\(RuntimeMetalEffectLibrary.defaultFunctionName)' not found in runtime effect '\(definition.uuid)'."
                if let runtimeWarning { print("⚠️ RuntimeMetalEffect: \(runtimeWarning)") }
                return false
            }

            var reflection: MTLAutoreleasedComputePipelineReflection?
            let pipeline = try device.makeComputePipelineState(
                function: function,
                options: [.argumentInfo, .bufferTypeInfo],
                reflection: &reflection
            )
            self.pipelineState = pipeline

            let arguments = reflection?.arguments.filter(\.isActive) ?? []
            guard validateArgumentBindings(arguments: arguments) else {
                return false
            }
            configureParameterLayout(arguments: arguments)
            return true
        } catch {
            runtimeWarning = "Failed to compile runtime effect '\(definition.uuid)': \(error.localizedDescription)"
            if let runtimeWarning { print("⚠️ RuntimeMetalEffect: \(runtimeWarning)") }
            return false
        }
    }

    private func validateArgumentBindings(arguments: [MTLArgument]) -> Bool {
        let activeTextureIndices = Set(
            arguments
                .filter { $0.type == .texture }
                .map { Int($0.index) }
        )

        let inputIndices = Set(definition.bindings.inputTextures.map(\.argumentIndex))
        let outputIndex = definition.bindings.outputTextureIndex
        var boundIndices = inputIndices
        boundIndices.insert(outputIndex)

        if activeTextureIndices != boundIndices {
            let missing = activeTextureIndices.subtracting(boundIndices).sorted()
            let extra = boundIndices.subtracting(activeTextureIndices).sorted()
            runtimeWarning = "Texture binding mismatch for runtime effect '\(definition.uuid)'. Missing: \(missing), extra: \(extra)."
            if let runtimeWarning { print("⚠️ RuntimeMetalEffect: \(runtimeWarning)") }
            return false
        }

        if let parameterBufferIndex = definition.bindings.parameterBufferIndex {
            let activeBufferIndices = Set(
                arguments
                    .filter { $0.type == .buffer }
                    .map { Int($0.index) }
            )
            if !activeBufferIndices.contains(parameterBufferIndex) {
                runtimeWarning = "Parameter buffer index \(parameterBufferIndex) not active for runtime effect '\(definition.uuid)'."
                if let runtimeWarning { print("⚠️ RuntimeMetalEffect: \(runtimeWarning)") }
                return false
            }
        }

        return true
    }

    private func configureParameterLayout(arguments: [MTLArgument]) {
        guard let parameterBufferIndex = definition.bindings.parameterBufferIndex else {
            parameterBufferLength = 0
            parameterBufferMembers = []
            return
        }

        guard let argument = arguments.first(where: { $0.type == .buffer && Int($0.index) == parameterBufferIndex }) else {
            parameterBufferLength = 0
            parameterBufferMembers = []
            return
        }

        parameterBufferLength = max(Int(argument.bufferDataSize), 1)

        guard let structType = argument.bufferStructType else {
            parameterBufferMembers = []
            return
        }

        parameterBufferMembers = structType.members
            .sorted { $0.offset < $1.offset }
            .compactMap { member in
                guard let scalarSize = Self.scalarSize(for: member.dataType) else { return nil }
                return RuntimeBufferMemberLayout(
                    name: member.name,
                    offset: Int(member.offset),
                    dataType: member.dataType,
                    size: scalarSize
                )
            }
    }

    private func makeTexture(from image: CIImage, width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        ciContext.render(image, to: texture, commandBuffer: nil, bounds: image.extent, colorSpace: colorSpace)
        return texture
    }

    // MARK: - Parameter Encoding

    private func fillParameterBuffer(
        data: inout Data,
        width: Int,
        height: Int,
        frameIndex: Int,
        time: CMTime
    ) {
        for member in parameterBufferMembers {
            let value = parameterValue(
                named: member.name,
                width: width,
                height: height,
                frameIndex: frameIndex,
                time: time
            )

            switch member.dataType {
            case .float:
                let encoded = value.floatValue ?? 0
                writeScalar(encoded, into: &data, offset: member.offset, size: member.size)

            case .int:
                let encodedValue = resolvedIntValue(for: member.name, from: value) ?? 0
                let encoded = Int32(encodedValue)
                writeScalar(encoded, into: &data, offset: member.offset, size: member.size)

            case .uint:
                let raw = resolvedIntValue(for: member.name, from: value) ?? 0
                let encoded = UInt32(max(0, raw))
                writeScalar(encoded, into: &data, offset: member.offset, size: member.size)

            case .bool:
                let encoded: UInt8 = (value.boolValue ?? false) ? 1 : 0
                writeScalar(encoded, into: &data, offset: member.offset, size: member.size)

            default:
                continue
            }
        }
    }

    private func parameterValue(
        named name: String,
        width: Int,
        height: Int,
        frameIndex: Int,
        time: CMTime
    ) -> AnyCodableValue {
        if definition.autoBoundParameters.contains(name) {
            switch name {
            case "timeSeconds":
                return .double(CMTimeGetSeconds(time))
            case "textureWidth":
                return .int(width)
            case "textureHeight":
                return .int(height)
            case "frameIndex":
                return .int(frameIndex)
            default:
                break
            }
        }

        if let value = parameterValues[name] {
            return value
        }
        return definition.allParameterDefaults[name] ?? .double(0)
    }

    private func resolvedHistoryOffset(for binding: RuntimeMetalTextureBindingManifest) -> Int {
        if let parameterName = binding.historyOffsetParameter {
            let runtimeValue = parameterValues[parameterName]
            let defaultValue = definition.allParameterDefaults[parameterName]
            let runtimeDouble = runtimeValue?.doubleValue
            let runtimeIntDouble = runtimeValue?.intValue.map(Double.init)
            let defaultDouble = defaultValue?.doubleValue
            let defaultIntDouble = defaultValue?.intValue.map(Double.init)
            let fallback = Double(binding.historyOffset ?? 1)
            let raw = runtimeDouble ?? runtimeIntDouble ?? defaultDouble ?? defaultIntDouble ?? fallback
            let scale = binding.historyOffsetScale ?? 1.0
            let bias = Double(binding.historyOffsetBias ?? 0)
            let computed = Int((raw * scale + bias).rounded())
            return max(1, computed)
        }
        return max(binding.historyOffset ?? 1, 1)
    }

    private func writeScalar<T>(_ value: T, into data: inout Data, offset: Int, size: Int) {
        guard offset >= 0, size > 0 else { return }
        let byteCount = MemoryLayout<T>.size
        guard byteCount <= size, offset + byteCount <= data.count else { return }
        var mutableValue = value
        withUnsafeBytes(of: &mutableValue) { bytes in
            data.replaceSubrange(offset..<(offset + byteCount), with: bytes)
        }
    }

    private func resolvedIntValue(for parameterName: String, from value: AnyCodableValue) -> Int? {
        if let intValue = value.intValue {
            return intValue
        }
        if let boolValue = value.boolValue {
            return boolValue ? 1 : 0
        }
        if let stringValue = value.stringValue,
           let spec = definition.parameterSpecs[parameterName],
           case .choice(_, let options) = spec,
           let index = options.firstIndex(where: { $0.key == stringValue }) {
            return index
        }
        return nil
    }

    private static func scalarSize(for type: MTLDataType) -> Int? {
        switch type {
        case .float, .int, .uint:
            return 4
        case .bool:
            return 1
        default:
            return nil
        }
    }
}
