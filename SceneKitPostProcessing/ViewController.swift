//
//  ViewController.swift
//  SceneKitPostProcessing
//
//  Created by Dennis Ippel on 06/05/2019.
//  Copyright © 2019 Dennis Ippel. All rights reserved.
//

import UIKit
import SceneKit
import ARKit

class ViewController: UIViewController, ARSCNViewDelegate {

    @IBOutlet var sceneView: ARSCNView!
    
    private var planeContainer: SCNNode!
    private var postProcessEffect: OutlinePostProcessEffect!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        sceneView.delegate = self
        sceneView.showsStatistics = true
        let scene = SCNScene(named: "art.scnassets/ship.scn")!
        planeContainer = scene.rootNode.childNode(withName: "ShipContainer", recursively: true)
        planeContainer.removeFromParentNode()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        sceneView.session.run(configuration)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        postProcessEffect = OutlinePostProcessEffect(withView: sceneView)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        let node = SCNNode()
     
        planeContainer.removeFromParentNode()
        node.addChildNode(planeContainer)
        
        return node
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        postProcessEffect.render(mainRenderer: renderer, scene: scene, atTime: time)
    }
}
