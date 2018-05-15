//
//  ViewController.m
//  VTEncode
//
//  Created by LiDinggui on 2018/5/11.
//  Copyright © 2018年 MKTECH. All rights reserved.
//

#import "ViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

@interface ViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate>
{
    VTCompressionSessionRef _encodeSession;
    dispatch_queue_t _encodeQueue;
    long _frameCount;
    FILE *_h264File;
    int _spsppsFound;
}

@property (nonatomic, copy) NSString *documentDirectory;
@property (nonatomic, strong) AVCaptureSession *videoCaptureSession;

@end

@implementation ViewController

#pragma mark - LifeCycle
- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _encodeQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    _frameCount = 0;
    
    self.documentDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    
    [self initVideoCapture];
}

- (void)dealloc
{
    [self stopVideoCapture];
}

#pragma mark - ClickEvent
- (IBAction)startButtonClicked:(UIButton *)sender
{
    [self startVideoCapture];
}

- (IBAction)stopButtonClicked:(UIButton *)sender
{
    [self stopVideoCapture];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    [self encodeFrame:sampleBuffer];
}

#pragma mark - 编码回调
//编码回调,每当系统编码完一帧之后,会异步调用该方法,此为C语言方法
void compressionOutputCallback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
    if (status != noErr)
    {
        return;
    }
    
    //不存在则代表压缩不成功或帧丢失, or if(!sampleBuffer) return;
    if (!CMSampleBufferDataIsReady(sampleBuffer))
    {
        return;
    }
    
    ViewController *vc = (__bridge ViewController *)outputCallbackRefCon;
    
    CFArrayRef array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (!array || CFArrayGetCount(array) <= 0)
    {
        return;
    }
    CFDictionaryRef dic = CFArrayGetValueAtIndex(array, 0);
    if (!dic)
    {
        return;
    }
    //判断当前帧是否为关键帧
    bool isKeyFrame = !CFDictionaryContainsKey(dic, kCMSampleAttachmentKey_NotSync);
    
    //获取sps & pps数据.sps pps只需获取一次,保存在h264文件开头即可
    if (isKeyFrame && !vc->_spsppsFound)
    {
        size_t spsSize, spsCount;
        size_t ppsSize, ppsCount;
        
        const uint8_t *spsData, *ppsData;
        
        CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        OSStatus err0 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &spsData, &spsSize, &spsCount, 0);
        OSStatus err1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &ppsData, &ppsSize, &ppsCount, 0);
        
        if (err0 == noErr && err1 == noErr)
        {
            vc->_spsppsFound = 1;
            [vc writeH264Data:(void *)spsData length:spsSize addStartCode:YES];
            [vc writeH264Data:(void *)ppsData length:ppsSize addStartCode:YES];
//          sps = [NSData dataWithBytes:spsData length:spsSize];
//          pps = [NSData dataWithBytes:ppsData length:ppsSize];
        }
    }
    
    size_t lengthAtOffset, totalLength;
    char *data;
    
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    OSStatus error = CMBlockBufferGetDataPointer(dataBuffer, 0, &lengthAtOffset, &totalLength, &data);
    
    if (error == noErr)
    {
        size_t offset = 0;
        static const int lengthInfoSize = 4; //返回的nalu数据前四个字节不是00 00 00 01的start code,而是大端模式的帧长度length
        
        while (offset < totalLength - lengthInfoSize)
        {
            uint32_t naluLength = 0;
            memcpy(&naluLength, data + offset, lengthInfoSize); //获取nalu的长度
            
            //大端模式转化为系统端模式,字节从高位反转到低位
            naluLength = CFSwapInt32BigToHost(naluLength);
            
            [vc writeH264Data:data + offset + lengthInfoSize length:naluLength addStartCode:YES];
//            RTAVVideoFrame *frame = [RTAVVideoFrame new];
//            frame.sps = sps;
//            frame.pps = pps;
//            frame.data = [NSData dataWithBytes:data + offset + lengthInfoSize length:naluLength];
            
            //读取下一个nalu,一次回调可能包含多个nalu
            offset += lengthInfoSize + naluLength;
        }
    }
}

#pragma mark - InitVideoCapture
- (void)initVideoCapture
{
    self.videoCaptureSession = [[AVCaptureSession alloc] init];
    self.videoCaptureSession.sessionPreset = AVCaptureSessionPreset640x480;
    
    AVCaptureDevice *captureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!captureDevice)
    {
        return;
    }
    
    AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:nil];
    if ([self.videoCaptureSession canAddInput:captureDeviceInput])
    {
        [self.videoCaptureSession addInput:captureDeviceInput];
    }
    
    AVCaptureVideoDataOutput *captureVideoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    captureVideoDataOutput.videoSettings = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(NSString *)kCVPixelBufferPixelFormatTypeKey];
    captureVideoDataOutput.alwaysDiscardsLateVideoFrames = YES;
    if ([self.videoCaptureSession canAddOutput:captureVideoDataOutput])
    {
        [self.videoCaptureSession addOutput:captureVideoDataOutput];
    }
    
    //设置采集图像的方向,如果不设置,采集回来的图像会是旋转90°的
    AVCaptureConnection *captureConnection = [captureVideoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    captureConnection.videoOrientation = AVCaptureVideoOrientationPortrait;
    
    [self.videoCaptureSession commitConfiguration];
    
    //添加预览
    AVCaptureVideoPreviewLayer *captureVideoPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.videoCaptureSession];
    captureVideoPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    captureVideoPreviewLayer.frame = CGRectMake(0.0, 50.0, self.view.bounds.size.width, self.view.bounds.size.height - 50.0 - 90.0);
    [self.view.layer addSublayer:captureVideoPreviewLayer];
    
    //摄像头采集queue
    dispatch_queue_t queue = dispatch_queue_create("VideoCaptureQueue", DISPATCH_QUEUE_SERIAL);
    [captureVideoDataOutput setSampleBufferDelegate:self queue:queue];
}

#pragma mark - Method Or Function
//编码一帧图像,使用queue,防止阻塞系统摄像头采集线程
- (void)encodeFrame:(CMSampleBufferRef)sampleBuffer
{
    dispatch_sync(_encodeQueue, ^{
        
        CVImageBufferRef imageBuffer = (CVImageBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
        
        CMTime pts = CMTimeMake(self->_frameCount, 1000);
        CMTime duration = kCMTimeInvalid;
        
        //如果使用异步运行, kVTEncodeInfo_Asynchronous 被设置；同步运行, kVTEncodeInfo_FrameDropped 被设置；设置NULL为不想接受这个信息.
        VTEncodeInfoFlags infoFlagsOut;
        
        OSStatus status = VTCompressionSessionEncodeFrame(self->_encodeSession, imageBuffer, pts, duration, NULL, NULL, &infoFlagsOut);
        
        if (status != noErr)
        {
            [self stopEncodeSession];
            return;
        }
        
    });
}

- (void)stopEncodeSession
{
    if (_encodeSession)
    {
        VTCompressionSessionCompleteFrames(_encodeSession, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_encodeSession);
        CFRelease(_encodeSession);
        _encodeSession = NULL;
    }
}

- (void)startVideoCapture
{
    //文件保存在Documents文件夹下，可以直接通过iTunes将文件导出到电脑，在plist文件中添加Application supports iTunes file sharing = YES
    //wb:以只写方式打开或新建一个二进制文件，只允许写数据。
    if (!_h264File) _h264File = fopen([[NSString stringWithFormat:@"%@/vt_encode.h264",self.documentDirectory] UTF8String], "wb");
    [self startEncodeSession:480 height:640 framerate:25 bitrate:640 * 1000];
    if (!self.videoCaptureSession.running) [self.videoCaptureSession startRunning];
}

- (void)stopVideoCapture
{
    if (self.videoCaptureSession.running) [self.videoCaptureSession stopRunning];
    
    [self stopEncodeSession];
    
    if (_h264File) fclose(_h264File);
}

- (int)startEncodeSession:(int)width height:(int)height framerate:(int)fps bitrate:(int)bt
{
    if (_encodeSession)
    {
        return 0;
    }
    
    OSStatus status;
    //当VTCompressionSessionEncodeFrame被调用压缩一次后会被异步调用. 注:当你设置NULL的时候,你需要调用VTCompressionSessionEncodeFrameWithOutputHandler方法进行压缩帧处理,支持iOS9.0以上
    VTCompressionOutputCallback encodeOutputCallback = compressionOutputCallback;
    status = VTCompressionSessionCreate(kCFAllocatorDefault, width, height, kCMVideoCodecType_H264, NULL, NULL, NULL, encodeOutputCallback, (__bridge void *)self, &_encodeSession);
    
    if (status != noErr)
    {
        return -1;
    }
    
    //设置实时编码输出,降低编码延迟
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    
    //h264 profile,直播一般使用baseline,可减少由于b帧带来的延时
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    
    //设置编码码率(比特率),如果不设置,默认将会以很低的码率编码,导致编码出来的视频很模糊
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bt)); //bps
    status += VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFArrayRef)@[@(bt*2/8), @1]); //Bps
    
    //设置关键帧间隔,即gop size
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(fps*2));
    
    //设置帧率,只用于初始化session,不是实际FPS
    status = VTSessionSetProperty(_encodeSession, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
    
    //可选
    status = VTCompressionSessionPrepareToEncodeFrames(_encodeSession);
    
    return 0;
}

//保存h264数据到文件
- (void)writeH264Data:(void *)data length:(size_t)length addStartCode:(BOOL)addStartCode
{
    //4字节的h264协议start code
    const Byte bytes[] = "\x00\x00\x00\x01";
    
    if (_h264File)
    {
        if (addStartCode)
        {
            fwrite(bytes, 1, 4, _h264File);
        }
        fwrite(data, 1, length, _h264File);
    }
    else
    {
        
    }
}

@end
