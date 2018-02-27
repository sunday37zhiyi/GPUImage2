import UIKit

public protocol RenderViewDelegate: class {
    func willDisplayFramebuffer(renderView: RenderView, framebuffer: Framebuffer)
    func didDisplayFramebuffer(renderView: RenderView, framebuffer: Framebuffer)
    func shouldDisplayNextFramebufferOnMainThread() -> Bool
}

// TODO: Add support for transparency
public class RenderView:UIView, ImageConsumer {
    public weak var delegate:RenderViewDelegate?
    
    public var backgroundRenderColor = Color.black
    public var fillMode = FillMode.preserveAspectRatio
    public var orientation:ImageOrientation = .portrait
    public var sizeInPixels:Size { get { return Size(width:Float(frame.size.width * contentScaleFactor), height:Float(frame.size.height * contentScaleFactor))}}
    
    public var shouldPresentWithTransaction = false
    
    public let sources = SourceContainer()
    public let maximumInputs:UInt = 1
    var displayFramebuffer:GLuint?
    var displayRenderbuffer:GLuint?
    var backingSize = GLSize(width:0, height:0)
    
    private lazy var displayShader:ShaderProgram = {
        return sharedImageProcessingContext.passthroughShader
    }()
    
    private var internalLayer: CAEAGLLayer!
    
    required public init?(coder:NSCoder) {
        super.init(coder:coder)
        self.commonInit()
    }
    
    public override init(frame:CGRect) {
        super.init(frame:frame)
        self.commonInit()
    }
    
    override public class var layerClass:Swift.AnyClass {
        get {
            return CAEAGLLayer.self
        }
    }
    
    override public var bounds: CGRect {
        didSet {
            // Check if the size changed
            if(oldValue.size != self.bounds.size) {
                // Destroy the displayFramebuffer so we render at the correct size for the next frame
                self.destroyDisplayFramebuffer()
            }
        }
    }
    
    func commonInit() {
        self.contentScaleFactor = UIScreen.main.scale
        
        let eaglLayer = self.layer as! CAEAGLLayer
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking: NSNumber(value:false), kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8]
        
        self.internalLayer = eaglLayer
    }
    
    deinit {
        destroyDisplayFramebuffer()
    }
    
    var waitingForTransaction = false
    func presentWithTransaction() {
        if #available(iOS 9.0, *) {
            self.internalLayer.presentsWithTransaction = true
            self.waitingForTransaction = true
            
            CATransaction.begin()
            CATransaction.setCompletionBlock({
                self.internalLayer.presentsWithTransaction = false
                self.waitingForTransaction = false
            })
            CATransaction.commit()
        }
    }
    
    func createDisplayFramebuffer() -> Bool {
        sharedImageProcessingContext.makeCurrentContext()
        var newDisplayFramebuffer:GLuint = 0
        glGenFramebuffers(1, &newDisplayFramebuffer)
        displayFramebuffer = newDisplayFramebuffer
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)
        
        var newDisplayRenderbuffer:GLuint = 0
        glGenRenderbuffers(1, &newDisplayRenderbuffer)
        displayRenderbuffer = newDisplayRenderbuffer
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        
        // Without the flush I occasionally get a warning from UIKit on the camera renderView and
        // when the warning comes in the renderView just stays black. This happens rarely but often enough to be a problem.
        // I tried a transaction and it doesn't silence it and this is likely why --> http://danielkbx.com/post/108060601989/catransaction-flush
        // This flush defeats the purpose of presentWithTransaction() so it should only be enabled when you need it.
        // The idea with presentWithTransaction() is to be able to change the bounds of this renderView, then draw contents into it
        // at the correct bounds without any blips in between. If you have this flush() in place it will force a layout pass in the middle of that
        // causing the old contents to be briefly distorted while the new contents are yet to be drawn.
        // That is why this shouldn't be used in media playback scenarios.
        if(!shouldPresentWithTransaction) {
            CATransaction.flush()
        }
        sharedImageProcessingContext.context.renderbufferStorage(Int(GL_RENDERBUFFER), from:self.internalLayer)
        
        var backingWidth:GLint = 0
        var backingHeight:GLint = 0
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)
        backingSize = GLSize(width:backingWidth, height:backingHeight)
        
        guard (backingWidth > 0 && backingHeight > 0) else {
            print("Warning: View had a zero size")
            
            if(self.internalLayer.bounds.width > 0 && self.internalLayer.bounds.height > 0) {
                print("Warning: View size \(self.internalLayer.bounds) may be too large ")
            }
            return false
        }
        
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), displayRenderbuffer!)
        
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        if (status != GLenum(GL_FRAMEBUFFER_COMPLETE)) {
            print("Warning: Display framebuffer creation failed with error: \(FramebufferCreationError(errorCode:status))")
            return false
        }
        
        // Prevent the first frame from prematurely drawing before the view is drawn to the screen at the right size
        // Aka we want to briefly synchronize UIKit with OpenGL. OpenGL draws immediately but UIKit draws in cycles.
        // Note: We have to wait for the transaction to finish (aka for the drawing cycle to finish) before we disable this
        // we can't just disable presentsWithTransaction after the first frame because it may even take a couple frames for
        // a UIKit drawing cycle to complete (rarely but sometimes)
        // Without this you will get weird content flashes when switching between videos of different size
        // since the content will be drawn into a view that which although has the right frame/bounds it is not
        // yet actually reflected on the screen. OpenGL would just draw right into the wrongly displayed view
        // as soon as presentBufferForDisplay() is called.
        // Source --> https://stackoverflow.com/a/30722276/1275014
        // Source --> https://developer.apple.com/documentation/quartzcore/caeagllayer/1618676-presentswithtransaction
        if(shouldPresentWithTransaction) {
            self.presentWithTransaction()
        }
        
        return true
    }
    
    func destroyDisplayFramebuffer() {
        sharedImageProcessingContext.runOperationSynchronously{
            if let displayFramebuffer = self.displayFramebuffer {
                var temporaryFramebuffer = displayFramebuffer
                glDeleteFramebuffers(1, &temporaryFramebuffer)
                self.displayFramebuffer = nil
            }
            
            if let displayRenderbuffer = self.displayRenderbuffer {
                var temporaryRenderbuffer = displayRenderbuffer
                glDeleteRenderbuffers(1, &temporaryRenderbuffer)
                self.displayRenderbuffer = nil
            }
        }
    }
    
    func activateDisplayFramebuffer() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), displayFramebuffer!)
        glViewport(0, 0, backingSize.width, backingSize.height)
    }
    
    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        let processFramebuffer = {
            // Don't bog down UIKIt with a bunch of framebuffers if we are waiting for a transaction to complete
            // otherwise we will block the main thread as it trys to catch up.
            if (self.waitingForTransaction) { return }
            
            self.delegate?.willDisplayFramebuffer(renderView: self, framebuffer: framebuffer)
            
            sharedImageProcessingContext.runOperationSynchronously {
                if (self.displayFramebuffer == nil && !self.createDisplayFramebuffer()) {
                    // Bail if we couldn't successfully create the displayFramebuffer
                    return
                }
                self.activateDisplayFramebuffer()
                
                clearFramebufferWithColor(self.backgroundRenderColor)
                
                let scaledVertices = self.fillMode.transformVertices(verticallyInvertedImageVertices, fromInputSize:framebuffer.sizeForTargetOrientation(self.orientation), toFitSize:self.backingSize)
                renderQuadWithShader(self.displayShader, vertices:scaledVertices, inputTextures:[framebuffer.texturePropertiesForTargetOrientation(self.orientation)])
                
                glBindRenderbuffer(GLenum(GL_RENDERBUFFER), self.displayRenderbuffer!)
                
                sharedImageProcessingContext.presentBufferForDisplay()
            }
            
            self.delegate?.didDisplayFramebuffer(renderView: self, framebuffer: framebuffer)
            
            sharedImageProcessingContext.runOperationSynchronously {
                framebuffer.unlock()
            }
        }
        
        if(self.delegate?.shouldDisplayNextFramebufferOnMainThread() ?? false) {
            // CAUTION: Never call sync from the sharedImageProcessingContext, it will cause cyclic thread deadlocks
            // If you are curious, change this to sync, then try trimming/scrubbing a video
            // Before that happens you will get a deadlock when someone calls runOperationSynchronously since the main thread is blocked
            // There is a way to get around this but then the first thing mentioned will happen
            DispatchQueue.main.async {
                processFramebuffer()
            }
        }
        else {
            processFramebuffer()
        }
    }
}

