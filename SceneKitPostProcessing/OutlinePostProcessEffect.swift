//
//  OutlinePostProcessEffect.swift
//  SceneKitPostProcessing
//
//  Created by Dennis Ippel on 06/05/2019.
//  Copyright © 2019 Dennis Ippel. All rights reserved.
//

import SceneKit

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
    
    private weak var sceneView: SCNView?
    
    private var backgroundCube: SCNNode!
    private var extrusionMaterial: SCNMaterial!
    private var maskMaterial: SCNMaterial!
    private var planeMaterials: [SCNMaterial]?
    private var quadMaterial: SCNMaterial!
    private var renderer: SCNRenderer!

    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var quadVertexBuffer: MTLBuffer!
    private var renderTextures: [Pass: MTLTexture] = [:]

    private var renderViewport: CGRect!
    
    init(withView view: SCNView) {
        super.init()
        setup(withView: view)
    }
    
    private func setup(withView view: SCNView) {
        guard
            let device = view.device,
            let layer = view.layer as? CAMetalLayer,
            let drawable = layer.nextDrawable()
        else {
            assertionFailure()
            return
        }
        
        self.sceneView = view
        
        // -- Offscreen renderer
        
        renderer = SCNRenderer(device: device, options: nil)
        renderer.delegate = self
        
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
        
        commandQueue = device.makeCommandQueue()
        
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = drawable.texture.pixelFormat
        textureDescriptor.width = drawable.texture.width
        textureDescriptor.height = drawable.texture.height
        textureDescriptor.usage = MTLTextureUsage(rawValue: MTLTextureUsage.renderTarget.rawValue |  MTLTextureUsage.shaderRead.rawValue)
        
        renderTextures[.fullRender] = device.makeTexture(descriptor: textureDescriptor)!
        renderTextures[.outlineExtrusion] = device.makeTexture(descriptor: textureDescriptor)!
        renderTextures[.outlineMask] = device.makeTexture(descriptor: textureDescriptor)!
        
        renderViewport = CGRect(x: 0, y: 0, width: view.frame.width * UIScreen.main.scale, height: view.frame.height * UIScreen.main.scale)
        
        // -- This background cube is used to hide the camera feed in the background.
        //    I haven't found another way to do this temporarily. I tried:
        //    - let backgroundContents = scene.background.contents
        //      scene.background.contents = UIColor.red
        //    Then when trying to switch back the background isn't restored:
        //    - scene.background.contents = backgroundContents
        //    So using this cube attached to the pointOfView as an alternative.
        
        backgroundCube = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
        
        let backgroundCubeMaterial = SCNMaterial()
        backgroundCubeMaterial.isDoubleSided = true
        backgroundCubeMaterial.lightingModel = .constant
        // -- Constant green color so we can easily distinguish the background
        //    pixels in the fragment shader.
        backgroundCubeMaterial.diffuse.contents = UIColor.green

        guard let camera = sceneView?.pointOfView?.camera else { return }
        
        // -- Set the cube's scale so it fits the frustum.
        let cubeScale = camera.zFar - camera.zNear
        backgroundCube.scale = SCNVector3(cubeScale, cubeScale, cubeScale)
        backgroundCube.geometry?.materials = [backgroundCubeMaterial]
        
        // -- The material for the extrusion pass. The geometry is extruded along
        //    its normal. The extruded mesh then gets a single constant color (blue).
        //    Ideally I'd set the lighting model to .constant but this causes a crash.
        //    So I'm changing the pixel color in the .fragment shader modifier instead.
        extrusionMaterial = SCNMaterial()
        extrusionMaterial.cullMode = .front
        
        let extrusionGeometry = """
        float3 modelNormal = normalize(_geometry.normal);
        float4 modelPosition = _geometry.position;
        const float extrusionMagnitude = 0.1;
        modelPosition += float4(modelNormal, 0.0) * extrusionMagnitude;
        _geometry.position = modelPosition;
        _geometry.normal = (scn_node.normalTransform * float4(in.normal, 1)).xyz;
        """
        
        let extrusionFragment = """
        _output.color.rgb = vec3(0.0, 0.0, 1.0);
        """
        
        extrusionMaterial.shaderModifiers = [
            SCNShaderModifierEntryPoint.geometry: extrusionGeometry,
            SCNShaderModifierEntryPoint.fragment: extrusionFragment
        ]
        
        maskMaterial = SCNMaterial()
        
        let maskFragment = """
        _output.color.rgb = vec3(1.0, 0.0, 0.0);
        """
        
        maskMaterial.shaderModifiers = [
            SCNShaderModifierEntryPoint.fragment: maskFragment
        ]
    }
    
    func render(mainRenderer: SCNSceneRenderer, scene: SCNScene, atTime time: TimeInterval) {
        renderer.scene = scene
        renderer.pointOfView = sceneView?.pointOfView
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTextures[.fullRender]
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        // -- First, do a full render. Ideally I would be able to use a copy of nextDrawable().texture that was
        //    rendered by SceneKit in the composite fragment shader. However, this doesn't seem
        //    to be possible. Can't blit it into another texture because that isn't allowed.
        
        currentPass = .fullRender
        
        let commandBuffer1 = commandQueue.makeCommandBuffer()!
        renderer.update(atTime: time)
        renderer.render(withViewport: renderViewport, commandBuffer: commandBuffer1, passDescriptor: renderPassDescriptor)
        commandBuffer1.commit()
        commandBuffer1.waitUntilCompleted()
        
        currentPass = .outlineExtrusion
        
        let commandBuffer2 = commandQueue.makeCommandBuffer()!
        renderer.update(atTime: time)
        renderPassDescriptor.colorAttachments[0].texture = renderTextures[.outlineExtrusion]

        renderer.render(withViewport: renderViewport, commandBuffer: commandBuffer2, passDescriptor: renderPassDescriptor)
        commandBuffer2.commit()
        commandBuffer2.waitUntilCompleted()

        currentPass = .outlineMask

        let commandBuffer3 = commandQueue.makeCommandBuffer()!
        renderer.update(atTime: time)
        renderPassDescriptor.colorAttachments[0].texture = renderTextures[.outlineMask]
        renderer.render(withViewport: renderViewport, commandBuffer: commandBuffer3, passDescriptor: renderPassDescriptor)
        commandBuffer3.commit()
        commandBuffer3.waitUntilCompleted()
        
        // -- Put everything together
        
        guard let encoder = sceneView?.currentRenderCommandEncoder else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(renderTextures[.fullRender], index: 0)
        encoder.setFragmentTexture(renderTextures[.outlineExtrusion], index: 1)
        encoder.setFragmentTexture(renderTextures[.outlineMask], index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}

extension OutlinePostProcessEffect: SCNSceneRendererDelegate {
    func renderer(_ renderer: SCNSceneRenderer,
                  updateAtTime time: TimeInterval) {
        guard
            let planeMesh = renderer.scene?.rootNode.childNode(withName: "ShipMesh", recursively: true),
            let shadowPlane = renderer.scene?.rootNode.childNode(withName: "ShadowPlane", recursively: true)
            else { return }
        
        switch currentPass {
        case .outlineMask:
            planeMesh.isHidden = false
            shadowPlane.isHidden = true
            planeMesh.geometry?.materials = [ maskMaterial ]
        case .outlineExtrusion:
            planeMesh.isHidden = false
            planeMesh.castsShadow = false
            shadowPlane.isHidden = true
            planeMesh.geometry?.materials = [ extrusionMaterial ]
            renderer.pointOfView?.addChildNode(backgroundCube)
        case .fullRender:
            planeMesh.isHidden = false
            planeMesh.castsShadow = true
            shadowPlane.isHidden = false
            
            if planeMaterials == nil {
                planeMaterials = planeMesh.geometry?.materials
            }
            
            planeMesh.geometry?.materials = planeMaterials!
            
            backgroundCube.removeFromParentNode()
        }
    }
}
