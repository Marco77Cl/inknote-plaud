import AppKit
import Foundation
let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
func render(_ size:Int) throws -> Data {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    let context=NSGraphicsContext(bitmapImageRep:rep)!
    NSGraphicsContext.current=context
    context.cgContext.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    NSColor.clear.setFill();NSRect(x:0,y:0,width:1024,height:1024).fill()
    let tile=NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:200,yRadius:200)
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.16);shadow.shadowBlurRadius=20;shadow.shadowOffset=NSSize(width:0,height:-8);shadow.set()
    NSColor(calibratedRed:0.965,green:0.961,blue:0.945,alpha:1).setFill();tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let symbol=NSImage(systemSymbolName:"waveform",accessibilityDescription:"InkNote waveform")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:500,weight:.medium)) else{fatalError("waveform symbol unavailable")}
    let box=NSRect(x:226,y:226,width:572,height:572)
    let ratio=min(box.width/symbol.size.width,box.height/symbol.size.height)
    let rect=NSRect(x:512-symbol.size.width*ratio/2,y:512-symbol.size.height*ratio/2,width:symbol.size.width*ratio,height:symbol.size.height*ratio)
    let tint=NSImage(size:symbol.size)
    tint.lockFocus();symbol.draw(in:NSRect(origin:.zero,size:symbol.size));NSColor(calibratedWhite:0.12,alpha:1).setFill();NSRect(origin:.zero,size:symbol.size).fill(using:.sourceIn);tint.unlockFocus()
    tint.draw(in:rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512] {
    try render(size).write(to:out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size*2).write(to:out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
