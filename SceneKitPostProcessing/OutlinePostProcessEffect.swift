//
//  OutlinePostProcessEffect.swift
//  SceneKitPostProcessing
//
//  Created by Dennis Ippel on 06/05/2019.
//  Copyright © 2019 Dennis Ippel. All rights reserved.
//

import ARKit

class OutlinePostProcessEffect: NSObject {
    enum Pass {
        case fullRender
        case outlineMask
        case outlineExtrusion
    }
    
    struct QuadVertex {
        var x, y, z: Float
        var u, v: Float
        
        func floatBuffer() -> [Float] {
            return [x, y, z, u, v]
        }
    }
    
    var currentPass: Pass = .fullRender
    
    private weak var sceneView: ARSCNView?
    
    private var extrusionMaterial: SCNMaterial!
    private var maskMaterial: SCNMaterial!
    private var planeMaterials: [SCNMaterial]?
    private var quadMaterial: SCNMaterial!
    private var offscreenRenderer: SCNRenderer!

    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var pipelineState2: MTLRenderPipelineState!
    private var quadVertexBuffer: MTLBuffer!
    private var renderTextures: [Pass: MTLTexture] = [:]

    private var renderViewport: CGRect!
    private var offscreenCameraNode: SCNNode!
    private var renderPassDescriptor: MTLRenderPassDescriptor!
    
    init(withView view: ARSCNView) {
        super.init()
        setup(withView: view)
    }
    
    private func setup(withView view: ARSCNView) {
        guard let device = view.device else {
            assertionFailure()
            return
        }

        self.sceneView = view
        
        // -- Offscreen renderer
        
        offscreenRenderer = SCNRenderer(device: device, options: nil)
        offscreenRenderer.delegate = self
        
        // -- Fullscreen quad
        
        let vertices: [QuadVertex] = [
            QuadVertex(x: -1, y:  1, z: 0, u: 0, v: 0),
            QuadVertex(x:  1, y: -1, z: 0, u: 1, v: 1),
            QuadVertex(x:  1, y:  1, z: 0, u: 1, v: 0),
            QuadVertex(x:  1, y: -1, z: 0, u: 1, v: 1),
            QuadVertex(x: -1, y:  1, z: 0, u: 0, v: 0),
            QuadVertex(x: -1, y: -1, z: 0, u: 0, v: 1)
        ]
        quadVertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<QuadVertex>.size * vertices.count,
            options: .cpuCacheModeWriteCombined)
        
        let library = device.makeDefaultLibrary()!
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthPixelFormat
        
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            else {
                assertionFailure()
                return
        }
        
        self.pipelineState = pipelineState
        
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "quad_fragment_full")
        
        guard let pipelineState2 = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            else {
                assertionFailure()
                return
        }
        
        self.pipelineState2 = pipelineState2
        
        commandQueue = device.makeCommandQueue()
        
        renderViewport = CGRect(x: 0, y: 0, width: view.frame.width * UIScreen.main.scale, height: view.frame.height * UIScreen.main.scale)
        
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = view.colorPixelFormat
        textureDescriptor.width = Int(renderViewport.maxX)
        textureDescriptor.height = Int(renderViewport.maxY)
        textureDescriptor.usage = MTLTextureUsage(rawValue: MTLTextureUsage.renderTarget.rawValue |  MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue)
        
        renderTextures[.fullRender] = device.makeTexture(descriptor: textureDescriptor)!
        textureDescriptor.usage = MTLTextureUsage(rawValue: MTLTextureUsage.renderTarget.rawValue |  MTLTextureUsage.shaderRead.rawValue)
        renderTextures[.outlineExtrusion] = device.makeTexture(descriptor: textureDescriptor)!
        renderTextures[.outlineMask] = device.makeTexture(descriptor: textureDescriptor)!
        
        // -- The material for the extrusion pass. The geometry is extruded along
        //    its normal. The extruded mesh then gets a single constant color (blue).
        extrusionMaterial = SCNMaterial()
        extrusionMaterial.isDoubleSided = true
        extrusionMaterial.lightingModel = .constant
        extrusionMaterial.diffuse.contents = UIColor.blue
        
        let extrusionGeometry = """
        float3 modelNormal = normalize(_geometry.normal);
        float4 modelPosition = _geometry.position;
        const float extrusionMagnitude = 0.1;
        modelPosition += float4(modelNormal, 0.0) * extrusionMagnitude;
        _geometry.position = modelPosition;
        _geometry.normal = (scn_node.normalTransform * float4(in.normal, 1)).xyz;
        """
        
        extrusionMaterial.shaderModifiers = [
            SCNShaderModifierEntryPoint.geometry: extrusionGeometry
        ]
        
        maskMaterial = SCNMaterial()
        maskMaterial.lightingModel = .constant
        maskMaterial.diffuse.contents = UIColor.red
        
        renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTextures[.fullRender]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        
        offscreenScene = SCNScene()
        offscreenCameraNode = SCNNode()
        offscreenCameraNode.camera = SCNCamera()
        offscreenScene.rootNode.addChildNode(offscreenCameraNode)
        offscreenRenderer.scene = offscreenScene
    }
    
    private var offscreenScene: SCNScene!
    
    func render(mainRenderer: SCNSceneRenderer, scene: SCNScene, atTime time: TimeInterval) {
    
        currentPass = .fullRender
        offscreenRenderer.update(atTime: time)
        
        guard let encoder = sceneView?.currentRenderCommandEncoder else { return }
        
        var viewportSize = float2(x: Float(renderViewport.maxX), y: Float(renderViewport.maxY))
        encoder.setRenderPipelineState(pipelineState2)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(renderTextures[.fullRender], index: 0)
        encoder.setFragmentBytes(&viewportSize, length: MemoryLayout<float2>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        
        currentPass = .outlineExtrusion
            
        let commandBuffer2 = commandQueue.makeCommandBuffer()!
        renderPassDescriptor.colorAttachments[0].texture = renderTextures[.outlineExtrusion]
        
        offscreenRenderer.render(atTime: time, viewport: renderViewport, commandBuffer: commandBuffer2, passDescriptor: renderPassDescriptor)
        commandBuffer2.commit()
        commandBuffer2.waitUntilCompleted()

        currentPass = .outlineMask

        let commandBuffer3 = commandQueue.makeCommandBuffer()!
        renderPassDescriptor.colorAttachments[0].texture = renderTextures[.outlineMask]
        offscreenRenderer.render(atTime: time, viewport: renderViewport, commandBuffer: commandBuffer3, passDescriptor: renderPassDescriptor)
        commandBuffer3.commit()
        commandBuffer3.waitUntilCompleted()
            
        // -- Put everything together
        
        guard let encoder2 = sceneView?.currentRenderCommandEncoder else { return }
        
        encoder2.setRenderPipelineState(pipelineState)
        encoder2.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        
        encoder2.setFragmentTexture(renderTextures[.fullRender], index: 0)
        encoder2.setFragmentTexture(renderTextures[.outlineExtrusion], index: 1)
        encoder2.setFragmentTexture(renderTextures[.outlineMask], index: 2)
        encoder2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        
        currentPass = .fullRender
        offscreenRenderer.update(atTime: time)
    }
    
    var nodeToAdd: SCNNode?
    
    func nodeAdded(_ node: SCNNode) {
        let clone = node.clone()
        clone.name = "NodeContainerParent"
        nodeToAdd = clone
    }
}

extension OutlinePostProcessEffect: SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer,
                  updateAtTime time: TimeInterval) {
        if let nodeToAdd = nodeToAdd {
            offscreenScene.rootNode.addChildNode(nodeToAdd)
            self.nodeToAdd = nil
        }

        guard
            let mainScene = sceneView?.scene,
            let planeMesh = offscreenScene.rootNode.childNode(withName: "NodeMesh", recursively: true),
            let planeMeshMain = mainScene.rootNode.childNode(withName: "NodeMesh", recursively: true),
            let shadowPlane = offscreenScene.rootNode.childNode(withName: "ShadowPlane", recursively: true),
            let light = offscreenScene.rootNode.childNode(withName: "DirectionalLight", recursively: true)?.light,
            let anchor = sceneView?.anchor(for: planeMeshMain)
        else { return }

        if let mainCamera = mainScene.rootNode.childNodes(passingTest: { (node, stop) -> Bool in
            return node.camera != nil
        }).first {
            offscreenCameraNode.transform = mainCamera.transform
            offscreenCameraNode.camera!.projectionTransform = mainCamera.camera!.projectionTransform
        }

        planeMesh.parent!.simdTransform = anchor.transform
        
        switch currentPass {
        case .outlineMask:
            light.shadowMode = .forward
            light.castsShadow = false
            planeMesh.isHidden = false
            shadowPlane.isHidden = true
            planeMesh.geometry?.materials = [ maskMaterial ]
        case .outlineExtrusion:
            light.shadowMode = .forward
            light.castsShadow = false
            planeMesh.isHidden = false
            planeMesh.castsShadow = false
            shadowPlane.isHidden = true
            planeMesh.geometry?.materials = [ extrusionMaterial ]
        case .fullRender:
            light.shadowMode = .deferred
            light.castsShadow = true
            planeMesh.isHidden = false
            planeMesh.castsShadow = true
            shadowPlane.isHidden = false

            if planeMaterials == nil {
                planeMaterials = planeMesh.geometry?.materials
            }

            planeMesh.geometry?.materials = planeMaterials!
        }
    }
}
