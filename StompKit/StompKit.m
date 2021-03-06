//
//  StompKit.m
//  StompKit
//
//  Created by Jeff Mesnil on 09/10/2013.
//  Copyright (c) 2013 Jeff Mesnil. All rights reserved.
//

#import "StompKit.h"
#import "GCDAsyncSocket.h"

#import <CocoaLumberjack/DDLog.h>

#define ENABLE_BACKGROUNDING  0

extern int ddLogLevel;

#define kDefaultTimeout 5
#define kVersion1_2 @"1.2"
#define kNoHeartBeat @"0,0"

#pragma mark Logging macros

#if 1 // set to 1 to enable logs

#define LogDebug(frmt, ...) DDLogVerbose(frmt, ##__VA_ARGS__);

#else

#define LogDebug(frmt, ...) {}

#endif

#pragma mark Frame commands

#define kCommandAbort       @"ABORT"
#define kCommandAck         @"ACK"
#define kCommandBegin       @"BEGIN"
#define kCommandCommit      @"COMMIT"
#define kCommandConnect     @"CONNECT"
#define kCommandConnected   @"CONNECTED"
#define kCommandDisconnect  @"DISCONNECT"
#define kCommandError       @"ERROR"
#define kCommandMessage     @"MESSAGE"
#define kCommandNack        @"NACK"
#define kCommandReceipt     @"RECEIPT"
#define kCommandSend        @"SEND"
#define kCommandSubscribe   @"SUBSCRIBE"
#define kCommandUnsubscribe @"UNSUBSCRIBE"

#pragma mark Control characters

#define	kLineFeed @"\x0A"
#define	kNullChar @"\x00"
#define kHeaderSeparator @":"

#pragma mark -
#pragma mark STOMP Client private interface

@implementation NSString (STOMPExtension)

- (NSString *)stomp_escapedString
{
    NSMutableString *mutableString = [self mutableCopy];
    [mutableString replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:NSLiteralSearch range:NSMakeRange(0, [mutableString length])];
    [mutableString replaceOccurrencesOfString:@":" withString:@"\\c" options:NSLiteralSearch range:NSMakeRange(0, [mutableString length])];
    [mutableString replaceOccurrencesOfString:@"\n" withString:@"\\n" options:NSLiteralSearch range:NSMakeRange(0, [mutableString length])];
    [mutableString replaceOccurrencesOfString:@"\r" withString:@"\\r" options:NSLiteralSearch range:NSMakeRange(0, [mutableString length])];
    return [NSString stringWithString:mutableString];
}

- (NSString *)stomp_unescapedString
{
    NSString *str = self;
    NSMutableString *mutableString = [self mutableCopy];
    NSUInteger len = [str length];
    unichar buffer[len+1];
    [str getCharacters:buffer range:NSMakeRange(0, len)];
    for (int i = 0; i < len; i++) {
        unichar c = buffer[i];
        if (c == '\\') {
            unichar nextC = buffer[++i];
            switch (nextC) {
                case '\\':
                    [mutableString replaceCharactersInRange:NSMakeRange(i-1, 1) withString:@"\\"];
                     break;
                case 'c':
                    [mutableString replaceCharactersInRange:NSMakeRange(i-1, 1) withString:@":"];
                    break;
                case 'n':
                    [mutableString replaceCharactersInRange:NSMakeRange(i-1, 1) withString:@"\n"];
                    break;
                case 'r':
                    [mutableString replaceCharactersInRange:NSMakeRange(i-1, 1) withString:@"\r"];
                    break;
            }
        } else {
            //[mutableString appendFormat:@"%C", c];
        }
    }
    return [NSString stringWithString:mutableString];
}

@end

@interface STOMPClient() <GCDAsyncSocketDelegate>

@property (nonatomic, retain) GCDAsyncSocket *socket;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *vhost;
@property (nonatomic) NSUInteger port;
@property (nonatomic) NSString *clientHeartBeat;
@property (nonatomic, weak) NSTimer *pinger;
@property (nonatomic, weak) NSTimer *ponger;

@property (nonatomic, strong) NSDictionary *connectHeaderDictionary;

@property (nonatomic, copy) void (^disconnectedHandler)(NSError *error);
@property (nonatomic, copy) void (^connectionCompletionHandler)(STOMPFrame *connectedFrame, NSError *error);
@property (nonatomic, retain) NSMutableDictionary *subscriptions;

- (void) sendFrameWithCommand:(NSString *)command
                      headers:(NSDictionary *)headers
                         body:(NSString *)body;

@end

#pragma mark STOMP Frame

@interface STOMPFrame()

- (id)initWithCommand:(NSString *)theCommand
              headers:(NSDictionary *)theHeaders
                 body:(NSString *)theBody;

- (NSData *)toData;

@end

@implementation STOMPFrame

@synthesize command, headers, body;

- (id)initWithCommand:(NSString *)theCommand
              headers:(NSDictionary *)theHeaders
                 body:(NSString *)theBody {
    if(self = [super init]) {
        command = theCommand;
        headers = theHeaders;
        body = theBody;
    }
    return self;
}

- (NSString *)toString {
    NSMutableString *frame = [NSMutableString stringWithString: [self.command stringByAppendingString:kLineFeed]];
    for (id key in self.headers) {
        NSString *escapedHeaderValue = [[self.headers[key] description] stomp_escapedString];
        [frame appendString:[NSString stringWithFormat:@"%@%@%@%@", key, kHeaderSeparator, escapedHeaderValue, kLineFeed]];
    }
    [frame appendString:kLineFeed];
    if (self.body) {
        [frame appendString:self.body];
    }
    [frame appendString:kNullChar];
    return frame;
}

- (NSData *)toData {
    return [[self toString] dataUsingEncoding:NSUTF8StringEncoding];
}

+ (STOMPFrame *) STOMPFrameFromData:(NSData *)data {
    NSData *strData = [data subdataWithRange:NSMakeRange(0, [data length])];
    NSString *msg = [[NSString alloc] initWithData:strData encoding:NSUTF8StringEncoding];
    LogDebug(@"<<< %@", msg);
    
    NSScanner *msgScanner = [NSScanner scannerWithString:msg];
    NSCharacterSet *lineFeedCharacterSet = [NSCharacterSet characterSetWithCharactersInString:kLineFeed];
    NSCharacterSet *headerSeparatorCharacterSet = [NSCharacterSet characterSetWithCharactersInString:[kHeaderSeparator stringByAppendingString:kLineFeed]];
    
    [msgScanner scanCharactersFromSet:lineFeedCharacterSet intoString:NULL];
    
    NSString *command = nil;
    [msgScanner scanUpToCharactersFromSet:lineFeedCharacterSet intoString:&command];
    
    NSString *headerKey = nil, *headerValue = nil;
    //NSString *header = nil;
    NSMutableDictionary *headers = [[NSMutableDictionary alloc] init];
    msgScanner.charactersToBeSkipped = nil;
    [msgScanner scanCharactersFromSet:lineFeedCharacterSet intoString:NULL];
    /*while ([msgScanner scanUpToCharactersFromSet:lineFeedCharacterSet intoString:&header]) {
     msgScanner.scanLocation++;
     //[msgScanner scanUpToCharactersFromSet:headerSeparatorCharacterSet intoString:&headerKey];
     //[msgScanner scanCharactersFromSet:headerSeparatorCharacterSet intoString:NULL];
     //[msgScanner scanUpToCharactersFromSet:lineFeedCharacterSet intoString:&headerValue];
     //[msgScanner scanCharactersFromSet:lineFeedCharacterSet intoString:NULL];
     //headers[headerKey] = headerValue;
     }*/
    while (YES) {
        if (![msgScanner scanUpToCharactersFromSet:headerSeparatorCharacterSet intoString:&headerKey])
            break;
        msgScanner.scanLocation++;
        [msgScanner scanUpToCharactersFromSet:lineFeedCharacterSet intoString:&headerValue];
        msgScanner.scanLocation++;
        
        NSString *unescapedHeaderValue = [headerValue stomp_unescapedString];
        headers[headerKey] = unescapedHeaderValue;
    }
    NSString *body = nil;
    msgScanner.scanLocation++;
    [msgScanner scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:kNullChar] intoString:&body];
    
    return [[STOMPFrame alloc] initWithCommand:command headers:headers body:body ?: @""];
}

- (NSString *)description {
    return [self toString];
}


@end

#pragma mark STOMP Message

@interface STOMPMessage()

@property (nonatomic, retain) STOMPClient *client;

+ (STOMPMessage *)STOMPMessageFromFrame:(STOMPFrame *)frame
                                 client:(STOMPClient *)client;

@end

@implementation STOMPMessage

@synthesize client;

- (id)initWithClient:(STOMPClient *)theClient
             headers:(NSDictionary *)theHeaders
                body:(NSString *)theBody {
    if (self = [super initWithCommand:kCommandMessage
                              headers:theHeaders
                                 body:theBody]) {
        self.client = theClient;
    }
    return self;
}

- (void)ack {
    [self ackWithCommand:kCommandAck headers:nil];
}

- (void)ack: (NSDictionary *)theHeaders {
    [self ackWithCommand:kCommandAck headers:theHeaders];
}

- (void)nack {
    [self ackWithCommand:kCommandNack headers:nil];
}

- (void)nack: (NSDictionary *)theHeaders {
    [self ackWithCommand:kCommandNack headers:theHeaders];
}

- (void)ackWithCommand: (NSString *)command
               headers: (NSDictionary *)theHeaders {
    NSMutableDictionary *ackHeaders = [[NSMutableDictionary alloc] initWithDictionary:theHeaders];
    if (self.headers[kHeaderAck]) {
        ackHeaders[kHeaderID] = self.headers[kHeaderAck];
        [self.client sendFrameWithCommand:command
                                  headers:ackHeaders
                                     body:nil];
    }
}

+ (STOMPMessage *)STOMPMessageFromFrame:(STOMPFrame *)frame
                                 client:(STOMPClient *)client {
    return [[STOMPMessage alloc] initWithClient:client headers:frame.headers body:frame.body];
}

@end

#pragma mark STOMP Subscription

@interface STOMPSubscription()

@property (nonatomic, retain) STOMPClient *client;

- (id)initWithClient:(STOMPClient *)theClient
          identifier:(NSString *)theIdentifier;

@end

@implementation STOMPSubscription

@synthesize client;
@synthesize identifier;

- (id)initWithClient:(STOMPClient *)theClient
          identifier:(NSString *)theIdentifier {
    if(self = [super init]) {
        self.client = theClient;
        identifier = [theIdentifier copy];
    }
    return self;
}

- (void)unsubscribe {
    [self.client sendFrameWithCommand:kCommandUnsubscribe
                              headers:@{kHeaderID: self.identifier}
                                 body:nil];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<STOMPSubscription identifier:%@>", identifier];
}

@end

#pragma mark STOMP Transaction

@interface STOMPTransaction()

@property (nonatomic, retain) STOMPClient *client;

- (id)initWithClient:(STOMPClient *)theClient
          identifier:(NSString *)theIdentifier;

@end

@implementation STOMPTransaction

@synthesize identifier;

- (id)initWithClient:(STOMPClient *)theClient
          identifier:(NSString *)theIdentifier {
    if(self = [super init]) {
        self.client = theClient;
        identifier = [theIdentifier copy];
    }
    return self;
}

- (void)commit {
    [self.client sendFrameWithCommand:kCommandCommit
                              headers:@{kHeaderTransaction: self.identifier}
                                 body:nil];
}

- (void)abort {
    [self.client sendFrameWithCommand:kCommandAbort
                              headers:@{kHeaderTransaction: self.identifier}
                                 body:nil];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<STOMPTransaction identifier:%@>", identifier];
}

@end

#pragma mark STOMP Client Implementation

@implementation STOMPClient

@synthesize socket, host, port, vhost;
@synthesize connectionCompletionHandler, disconnectedHandler, receiptHandler, errorHandler;
@synthesize subscriptions;
@synthesize pinger, ponger;

int idGenerator;
CFAbsoluteTime serverActivity;

#pragma mark -
#pragma mark Public API

- (id)initWithHost:(NSString *)aHost
              port:(NSUInteger)aPort {
    if(self = [super init]) {
        self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self
                                                 delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
        self.host = aHost;
        self.vhost = @"/";
        self.port = aPort;
        idGenerator = 0;
        self.connected = NO;
        self.subscriptions = [[NSMutableDictionary alloc] init];
        self.clientHeartBeat = @"5000,10000";
    }
    return self;
}

- (id)initWithHost:(NSString *)aHost
              port:(NSUInteger)aPort virtualHost:(NSString *)aVhost {
    if(self = [self initWithHost:aHost port:aPort]) {
        self.vhost = aVhost;
    }
    return self;
}

- (void)connectWithLogin:(NSString *)login
                passcode:(NSString *)passcode
       completionHandler:(void (^)(STOMPFrame *connectedFrame, NSError *error))completionHandler {
    [self connectWithHeaders:@{kHeaderLogin: login, kHeaderPasscode: passcode}
           completionHandler:completionHandler];
}

- (void)connectWithHeaders:(NSDictionary *)headers
         completionHandler:(void (^)(STOMPFrame *connectedFrame, NSError *error))completionHandler {
    self.connectionCompletionHandler = completionHandler;
    
    NSError *err;
    if(![self.socket connectToHost:host onPort:port error:&err]) {
        if (self.connectionCompletionHandler) {
            self.connectionCompletionHandler(nil, err);
        }
    } else {
        self.connectHeaderDictionary = headers;
    }
}

- (void)sendTo:(NSString *)destination
          body:(NSString *)body {
    [self sendTo:destination
         headers:nil
            body:body];
}

- (void)sendTo:(NSString *)destination
       headers:(NSDictionary *)headers
          body:(NSString *)body {
    NSMutableDictionary *msgHeaders = [NSMutableDictionary dictionaryWithDictionary:headers];
    msgHeaders[kHeaderDestination] = destination;
    if (body) {
        msgHeaders[kHeaderContentLength] = [NSNumber numberWithLong:[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    }
    [self sendFrameWithCommand:kCommandSend
                       headers:msgHeaders
                          body:body];
}

- (STOMPSubscription *)subscribeTo:(NSString *)destination
                    messageHandler:(STOMPMessageHandler)handler {
    return [self subscribeTo:destination
                     headers:nil
              messageHandler:handler];
}

- (STOMPSubscription *)subscribeTo:(NSString *)destination
                           headers:(NSDictionary *)headers
                    messageHandler:(STOMPMessageHandler)handler {
    NSMutableDictionary *subHeaders = [[NSMutableDictionary alloc] initWithDictionary:headers];
    subHeaders[kHeaderDestination] = destination;
    NSString *identifier = subHeaders[kHeaderID];
    if (!identifier) {
        identifier = [NSString stringWithFormat:@"sub-%d", idGenerator++];
        subHeaders[kHeaderID] = identifier;
    }
    self.subscriptions[identifier] = handler;
    [self sendFrameWithCommand:kCommandSubscribe
                       headers:subHeaders
                          body:nil];
    return [[STOMPSubscription alloc] initWithClient:self identifier:identifier];
}

- (STOMPTransaction *)begin {
    NSString *identifier = [NSString stringWithFormat:@"tx-%d", idGenerator++];
    return [self begin:identifier];
}

- (STOMPTransaction *)begin:(NSString *)identifier {
    [self sendFrameWithCommand:kCommandBegin
                       headers:@{kHeaderTransaction: identifier}
                          body:nil];
    return [[STOMPTransaction alloc] initWithClient:self identifier:identifier];
}

- (void)disconnect {
    [self disconnect: nil];
}

- (void)disconnect:(void (^)(NSError *error))completionHandler {
    self.disconnectedHandler = completionHandler;
    [self sendFrameWithCommand:kCommandDisconnect
                       headers:nil
                          body:nil];
    [self.subscriptions removeAllObjects];
    [self.pinger invalidate];
    [self.ponger invalidate];
    [self.socket disconnect];
}


#pragma mark -
#pragma mark Private Methods

- (void)sendFrameWithCommand:(NSString *)command
                     headers:(NSDictionary *)headers
                        body:(NSString *)body {
    if ([self.socket isDisconnected]) {
        return;
    }
    STOMPFrame *frame = [[STOMPFrame alloc] initWithCommand:command headers:headers body:body];
    LogDebug(@">>> %@", frame);
    NSData *data = [frame toData];
    [self.socket writeData:data withTimeout:kDefaultTimeout tag:123];
}

- (void)sendPing:(NSTimer *)timer  {
    if ([self.socket isDisconnected]) {
        return;
    }
    [self.socket writeData:[GCDAsyncSocket LFData] withTimeout:kDefaultTimeout tag:123];
    LogDebug(@">>> PING");
}

- (void)checkPong:(NSTimer *)timer  {
    NSDictionary *dict = timer.userInfo;
    NSInteger ttl = [dict[@"ttl"] intValue];
    
    CFAbsoluteTime delta = CFAbsoluteTimeGetCurrent() - serverActivity;
    if (delta > (ttl * 2)) {
        LogDebug(@"did not receive server activity for the last %f seconds", delta);
        [self disconnect:errorHandler];
    }
}

- (void)setupHeartBeatWithClient:(NSString *)clientValues
                          server:(NSString *)serverValues {
    NSInteger cx, cy, sx, sy;
    
    NSScanner *scanner = [NSScanner scannerWithString:clientValues];
    scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@", "];
    [scanner scanInteger:&cx];
    [scanner scanInteger:&cy];
    
    scanner = [NSScanner scannerWithString:serverValues];
    scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@", "];
    [scanner scanInteger:&sx];
    [scanner scanInteger:&sy];
    
    NSInteger pingTTL = ceil(MAX(cx, sy) / 1000);
    NSInteger pongTTL = ceil(MAX(sx, cy) / 1000);
    
    LogDebug(@"send heart-beat every %ld seconds", pingTTL);
    LogDebug(@"expect to receive heart-beats every %ld seconds", pongTTL);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (pingTTL > 0) {
            NSTimer *_pinger = [NSTimer timerWithTimeInterval: pingTTL
                                                       target: self
                                                     selector: @selector(sendPing:)
                                                     userInfo: nil
                                                      repeats: YES];
            [[NSRunLoop mainRunLoop] addTimer:_pinger forMode:NSRunLoopCommonModes];
            [self.pinger invalidate];
            self.pinger = _pinger;
            [_pinger fire];
        }
        if (pongTTL > 0) {
            NSTimer *_ponger = [NSTimer timerWithTimeInterval: 1
                                                       target: self
                                                     selector: @selector(checkPong:)
                                                     userInfo: @{@"ttl": [NSNumber numberWithInteger:pongTTL]}
                                                      repeats: YES];
            [[NSRunLoop mainRunLoop] addTimer:_ponger forMode:NSRunLoopCommonModes];
            [self.ponger invalidate];
            self.ponger = _ponger;
            [_ponger fire];
        }
    });
    
}

- (void)receivedFrame:(STOMPFrame *)frame {
    // CONNECTED
    if([kCommandConnected isEqual:frame.command]) {
        self.connected = YES;
        [self setupHeartBeatWithClient:self.clientHeartBeat server:frame.headers[kHeaderHeartBeat]];
        if (self.connectionCompletionHandler) {
            self.connectionCompletionHandler(frame, nil);
        }
        // MESSAGE
    } else if([kCommandMessage isEqual:frame.command]) {
        STOMPMessageHandler handler = self.subscriptions[frame.headers[kHeaderSubscription]];
        if (handler) {
            STOMPMessage *message = [STOMPMessage STOMPMessageFromFrame:frame
                                                                 client:self];
            handler(message);
        } else {
            //TODO default handler
        }
        // RECEIPT
    } else if([kCommandReceipt isEqual:frame.command]) {
        if (self.receiptHandler) {
            self.receiptHandler(frame);
        }
        // ERROR
    } else if([kCommandError isEqual:frame.command]) {
        NSError *error = [[NSError alloc] initWithDomain:@"StompKit" code:1 userInfo:@{@"frame": frame}];
        // ERROR coming after the CONNECT frame
        if (!self.connected && self.connectionCompletionHandler) {
            self.connectionCompletionHandler(frame, error);
        } else if (self.errorHandler) {
            self.errorHandler(error);
        } else {
            LogDebug(@"Unhandled ERROR frame: %@", frame);
        }
    } else {
        NSError *error = [[NSError alloc] initWithDomain:@"StompKit"
                                                    code:2
                                                userInfo:@{@"message": [NSString stringWithFormat:@"Unknown frame %@", frame.command],
                                                           @"frame": frame}];
        if (self.errorHandler) {
            self.errorHandler(error);
        }
    }
}

- (void)readFrame {
    [[self socket] readDataToData:[GCDAsyncSocket ZeroData] withTimeout:-1 tag:0];
}

#pragma mark -
#pragma mark GCDAsyncSocketDelegate
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    DDLogVerbose(@"didWriteDataWithTag: %ld", tag);
}

- (void)socket:(GCDAsyncSocket *)sock
   didReadData:(NSData *)data
       withTag:(long)tag {
    serverActivity = CFAbsoluteTimeGetCurrent();
    STOMPFrame *frame = [STOMPFrame STOMPFrameFromData:data];
    [self receivedFrame:frame];
    [self readFrame];
}

- (void)socket:(GCDAsyncSocket *)sock didReadPartialDataOfLength:(NSUInteger)partialLength tag:(long)tag {
    LogDebug(@"<<< PONG");
    serverActivity = CFAbsoluteTimeGetCurrent();
}

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    
    
    if (self.sslEnabled) {
        // Connected to secure server (HTTPS)
        
#if ENABLE_BACKGROUNDING && !TARGET_IPHONE_SIMULATOR
        {
            // Backgrounding doesn't seem to be supported on the simulator yet
            
            [sock performBlock:^{
                if ([sock enableBackgroundingOnSocket])
                    DDLogInfo(@"Enabled backgrounding on socket");
                else
                    DDLogWarn(@"Enabling backgrounding failed!");
            }];
        }
#endif
        
        // Configure SSL/TLS settings
        NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithCapacity:3];
        
        // If you simply want to ensure that the remote host's certificate is valid,
        // then you can use an empty dictionary.
        
        // If you know the name of the remote host, then you should specify the name here.
        //
        // NOTE:
        // You should understand the security implications if you do not specify the peer name.
        // Please see the documentation for the startTLS method in GCDAsyncSocket.h for a full discussion.
        
        [settings setObject:self.host forKey:(NSString *)kCFStreamSSLPeerName];
        
#if TARGET_OS_IPHONE
        [settings setObject:@YES forKey:GCDAsyncSocketUseCFStreamForTLS];
#endif
        //[settings setObject:@YES forKey:GCDAsyncSocketManuallyEvaluateTrust];
        
        //[settings setObject:@(kTLSProtocol12) forKey:GCDAsyncSocketSSLProtocolVersionMin];
        //[settings setObject:@(kTLSProtocol12) forKey:GCDAsyncSocketSSLProtocolVersionMax];
        
        // To connect to a test server, with a self-signed certificate, use settings similar to this:
        
        //	// Allow expired certificates
        //	[settings setObject:[NSNumber numberWithBool:YES]
        //				 forKey:(NSString *)kCFStreamSSLAllowsExpiredCertificates];
        //
        //	// Allow self-signed certificates
        //	[settings setObject:[NSNumber numberWithBool:YES]
        //				 forKey:(NSString *)kCFStreamSSLAllowsAnyRoot];
        //
        //	// In fact, don't even validate the certificate chain
        //	[settings setObject:[NSNumber numberWithBool:NO]
        //				 forKey:(NSString *)kCFStreamSSLValidatesCertificateChain];
        
        DDLogInfo(@"Starting TLS with settings:\n%@", settings);
        
        [sock startTLS:settings];
        
        // You can also pass nil to the startTLS method, which is the same as passing an empty dictionary.
        // Again, you should understand the security implications of doing so.
        // Please see the documentation for the startTLS method in GCDAsyncSocket.h for a full discussion.
        
    } else {
        // Connected to normal server (HTTP)
        
#if ENABLE_BACKGROUNDING && !TARGET_IPHONE_SIMULATOR
        {
            // Backgrounding doesn't seem to be supported on the simulator yet
            
            [sock performBlock:^{
                if ([sock enableBackgroundingOnSocket])
                    DDLogInfo(@"Enabled backgrounding on socket");
                else
                    DDLogWarn(@"Enabling backgrounding failed!");
            }];
        }
#endif
        
        [self socketDidSecure:nil];
    }
}

- (void)socket:(GCDAsyncSocket *)sock didReceiveTrust:(SecTrustRef)trust completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler
{
    completionHandler(YES);
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock
{
    DDLogInfo(@"socketDidSecure:%p", sock);
    
    NSMutableDictionary *connectHeaders = [[NSMutableDictionary alloc] initWithDictionary:self.connectHeaderDictionary];
    connectHeaders[kHeaderAcceptVersion] = kVersion1_2;
    if (!connectHeaders[kHeaderHost]) {
        connectHeaders[kHeaderHost] = vhost;
    }
    if (!connectHeaders[kHeaderHeartBeat]) {
        connectHeaders[kHeaderHeartBeat] = self.clientHeartBeat;
    } else {
        self.clientHeartBeat = connectHeaders[kHeaderHeartBeat];
    }
    
    [self sendFrameWithCommand:kCommandConnect
                       headers:connectHeaders
                          body: nil];
    
    [self readFrame];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock
                  withError:(NSError *)err {
    DDLogError(@"socket did disconnect: %@", err);
    if (!self.connected && self.connectionCompletionHandler) {
        self.connectionCompletionHandler(nil, err);
    } else if (self.connected) {
        if (self.disconnectedHandler) {
            self.disconnectedHandler(err);
        } else if (self.errorHandler) {
            self.errorHandler(err);
        }
    }
    self.connected = NO;
}

@end
