// Run on a MetalFX-capable Mac: swift Tests/ClarityGPUCheck.swift
// Add 1200 to check 1920×1200 → 3840×2400.
// Add 1080 2400 to check the 1080p60 → 16:10 display mode.
// Executes the actual shaders on GPU; checks flat colors, black, edge range,
// detail enhancement, and an unprocessed comparison half at 3840×2160.
import Foundation
import Metal
import MetalFX
let inputHeight = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1080
precondition(inputHeight == 1080 || inputHeight == 1200)
let outputHeight = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? inputHeight * 2
precondition(outputHeight == inputHeight * 2 || (inputHeight == 1080 && outputHeight == 2400))
let device = MTLCreateSystemDefaultDevice()!
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let shader = repository.appendingPathComponent("BroadcastPlayer/Metal/Shaders/Compositor.metal")
let library = try device.makeLibrary(source: String(contentsOf: shader, encoding: .utf8), options: nil)
let descriptor = MTLRenderPipelineDescriptor()
descriptor.vertexFunction = library.makeFunction(name: "compositor_vertex")!
descriptor.fragmentFunction = library.makeFunction(name: "compositor_fragment_clarity")!
descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
let queue = device.makeCommandQueue()!
func texture(_ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ privateStorage: Bool = false) -> MTLTexture {
 let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
 d.usage = usage; d.storageMode = privateStorage ? .private : .shared
 return device.makeTexture(descriptor: d)!
}
let sd = MTLFXSpatialScalerDescriptor()
sd.inputWidth=1920; sd.inputHeight=inputHeight; sd.outputWidth=3840; sd.outputHeight=outputHeight
sd.colorTextureFormat = .bgra8Unorm; sd.outputTextureFormat = .bgra8Unorm; sd.colorProcessingMode = .perceptual
let scaler = sd.makeSpatialScaler(device: device)!
let input = texture(1920,inputHeight,scaler.colorTextureUsage.union(.shaderRead))
let fx = texture(3840,outputHeight,scaler.outputTextureUsage.union(.shaderRead),true)
let output = texture(3840,outputHeight,.renderTarget)
var bytes = [UInt8](repeating:0,count:1920*inputHeight*4)
func render(_ strength: Float, _ compare: Float) -> ([UInt8], Double) {
 let cb=queue.makeCommandBuffer()!
 scaler.colorTexture=input; scaler.outputTexture=fx; scaler.inputContentWidth=1920; scaler.inputContentHeight=inputHeight
 scaler.encode(commandBuffer: cb)
 let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output;pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
 let e=cb.makeRenderCommandEncoder(descriptor:pass)!; e.setRenderPipelineState(pipeline)
 var fit=SIMD4<Float>(1,1,0,0);var params:[Float]=[strength,compare,3840,0]
 e.setVertexBytes(&fit,length:16,index:0);e.setFragmentBytes(&params,length:16,index:0)
 e.setFragmentTexture(fx,index:0);e.setFragmentTexture(input,index:1)
 e.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4);e.endEncoding();cb.commit();cb.waitUntilCompleted()
 precondition(cb.status == .completed,"GPU failure: \(String(describing:cb.error))")
 var result=[UInt8](repeating:0,count:3840*outputHeight*4)
 output.getBytes(&result,bytesPerRow:3840*4,from:MTLRegionMake2D(0,0,3840,outputHeight),mipmapLevel:0)
 return(result,(cb.gpuEndTime-cb.gpuStartTime)*1000)
}
for pattern in ["constant", "black", "edge", "detail"] {
 for y in 0..<inputHeight {for x in 0..<1920 {
  let v:UInt8
  switch pattern {
   case "constant":v=102
   case "black":v=0
   case "edge":v=x<960 ? 51:204
   default:v=UInt8(100+Int(70*sin(Double(x)*0.7)*cos(Double(y)*0.5)))
  }
  for c in 0..<3 {bytes[(y*1920+x)*4+c]=v};bytes[(y*1920+x)*4+3]=255
 }}
 input.replace(region:MTLRegionMake2D(0,0,1920,inputHeight),mipmapLevel:0,withBytes:bytes,bytesPerRow:1920*4)
 let(base,_)=render(0,0)
 for strength:Float in [0.35,1] {
  let(result,ms)=render(strength,0)
  var changed=0
  for y in 0..<outputHeight {for x in 0..<3840 {
   let i=(y*3840+x)*4;precondition(result[i+3]==255)
   let v=Int(result[i]);if v != Int(base[i]) {changed+=1}
   if pattern=="constant" {precondition(abs(v-102)<=1,"Flat color changed")}
   if pattern=="black" {precondition(v==0,"Black changed / NaN")}
   if pattern=="edge" && x>3 && x<3836 {
    // The added sharpening cannot overshoot the neighborhood delivered by MetalFX.
    let neighbors=[base[i],base[i-4],base[i+4],base[max(0,i-3840*4)],base[min(base.count-4,i+3840*4)]]
    precondition(v>=Int(neighbors.min()!)-1 && v<=Int(neighbors.max()!)+1,"CAS added halo")
   }
  }}
  if pattern=="detail" {precondition(changed>100000,"Sharpening had no visible effect")}
  print("\(pattern), sharpness \(strength): PASS, changed \(changed) pixels, GPU \(String(format:"%.2f",ms)) ms")
 }
 let(split,_)=render(0.35,1)
 for y in stride(from:0,to:outputHeight,by:17) {for x in stride(from:0,to:1918,by:13) {
  let sx=(Double(x)+0.5)/2-0.5,sy=(Double(y)+0.5)*Double(inputHeight)/Double(outputHeight)-0.5
  let x0=max(0,min(1919,Int(floor(sx)))),x1=max(0,min(1919,Int(floor(sx))+1))
  let y0=max(0,min(inputHeight-1,Int(floor(sy)))),y1=max(0,min(inputHeight-1,Int(floor(sy))+1))
  let tx=sx-floor(sx),ty=sy-floor(sy)
  let a=Double(bytes[(y0*1920+x0)*4])*(1-tx)+Double(bytes[(y0*1920+x1)*4])*tx
  let b=Double(bytes[(y1*1920+x0)*4])*(1-tx)+Double(bytes[(y1*1920+x1)*4])*tx
  precondition(abs(Double(split[(y*3840+x)*4])-(a*(1-ty)+b*ty))<=2,"Comparison original was processed")
 }}
 print("Comparison original untouched: PASS")
}
