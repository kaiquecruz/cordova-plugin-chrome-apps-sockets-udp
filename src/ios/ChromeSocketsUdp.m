// Copyright (c) 2014 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Cordova/CDVPlugin.h>
#import "GCDAsyncUdpSocket.h"
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>

#ifndef CHROME_SOCKETS_UDP_VERBOSE_LOGGING
#define CHROME_SOCKETS_UDP_VERBOSE_LOGGING 0
#endif

#if CHROME_SOCKETS_UDP_VERBOSE_LOGGING
#define VERBOSE_LOG NSLog
#else
#define VERBOSE_LOG(args...) do {} while (false)
#endif

#if CHROME_SOCKETS_UDP_VERBOSE_LOGGING
static NSString* stringFromData(NSData* data) {
    NSUInteger len = [data length];
    if (len > 200) {
        len = 200;
    }
    char* buf = (char*)malloc(len + 1);
    memcpy(buf, [data bytes], len);
    buf[len] = 0;
    NSString* ret = [NSString stringWithUTF8String:buf];
    free(buf);
    return ret;
}
#endif  // CHROME_SOCKETS_UDP_VERBOSE_LOGGING

#pragma mark ChromeSocketsUdp interface

@interface ChromeSocketsUdp : CDVPlugin {
    ChromeSocketsUdpSocket _socket;
    NSUInteger _socketId;
    NSString* _receiveEventsCallbackId;
}

- (void)create:(CDVInvokedUrlCommand*)command;
- (void)bind:(CDVInvokedUrlCommand*)command;
- (void)send:(CDVInvokedUrlCommand*)command;
- (void)close:(CDVInvokedUrlCommand*)command;
- (void)setBroadcast:(CDVInvokedUrlCommand*)command;
- (void)registerReceiveEvents:(CDVInvokedUrlCommand*)command;
- (void)closeSocket: callbackId:(NSString*)theCallbackId;
- (void)fireReceiveEventsWithSocket: data:(NSData*)theData address:(NSString*)theAddress port:(NSUInteger)thePort;
- (void)fireReceiveErrorEventsWithSocket: error:(NSError*)theError;
@end

#pragma mark ChromeSocketsUdpSocket interface

@interface ChromeSocketsUdpSocket : NSObject {
    @public
    __weak ChromeSocketsUdp* _plugin;

    NSUInteger _socketId;
    NSNumber* _persistent;
    NSString* _name;
    NSNumber* _bufferSize;
    NSNumber* _paused;
    
    GCDAsyncUdpSocket* _socket;

    NSMutableArray* _sendCallbacks;
    
    id _closeCallback;
    
    NSMutableSet* _multicastGroups;
}
@end

@implementation ChromeSocketsUdpSocket

- (ChromeSocketsUdpSocket*)initWithId:(NSUInteger)theSocketId plugin:(ChromeSocketsUdp*)thePlugin properties:(NSDictionary*)theProperties
{
    self = [super init];
    if (self) {
        _socketId = theSocketId;
        _plugin = thePlugin;
        _paused = [NSNumber numberWithBool:NO];
        
        _sendCallbacks = [NSMutableArray array];
        _closeCallback = nil;
        
        _socket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
       
        [_socket enableBroadcast:YES error:nil];
        _multicastGroups = [NSMutableSet set];
        
        [self setProperties:theProperties];
    }
    return self;
}

- (void)setProperties:(NSDictionary*)theProperties
{
    NSNumber* persistent = theProperties[@"persistent"];
    NSString* name = theProperties[@"name"];
    NSNumber* bufferSize = theProperties[@"bufferSize"];

    if (persistent)
        _persistent = persistent;
    
    if (name)
        _name = name;
    
    if (bufferSize)
        _bufferSize = bufferSize;
    
    // Set undefined properties to default value.
    if (_persistent == nil)
        _persistent = [NSNumber numberWithBool:NO];
    
    if (_name == nil)
        _name = @"";
    
    if (_bufferSize == nil)
        _bufferSize = [NSNumber numberWithInteger:4096];
    
    if ([_socket isIPv4]) {
        if ([_bufferSize integerValue] > UINT16_MAX) {
           [_socket setMaxReceiveIPv4BufferSize:UINT16_MAX];
        } else {
            [_socket setMaxReceiveIPv4BufferSize:[_bufferSize integerValue]];
        }
    }
    
    if ([_socket isIPv6]) {
        if ([bufferSize integerValue] > UINT32_MAX) {
            [_socket setMaxReceiveIPv6BufferSize:UINT32_MAX];
        } else {
            [_socket setMaxReceiveIPv6BufferSize:[_bufferSize integerValue]];
        }
    }
}

- (void)setPaused:(NSNumber*)paused
{
    if (![_paused isEqualToNumber:paused]) {
        _paused = paused;
        if ([_paused boolValue]) {
            [_socket pauseReceiving];
        } else {
            [_socket beginReceiving:nil];
        }
    }
}

- (void)udpSocket:(GCDAsyncUdpSocket*)sock didSendDataWithTag:(long)tag
{
    VERBOSE_LOG(@"udpSocket:didSendDataWithTag socketId: %u", _socketId);

    assert([_sendCallbacks count] != 0);
    void (^ callback)(BOOL, NSError*) = _sendCallbacks[0];
    assert(callback != nil);
    [_sendCallbacks removeObjectAtIndex:0];

    callback(YES, nil);
}

- (void)udpSocket:(GCDAsyncUdpSocket*)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error
{
    VERBOSE_LOG(@"udpSocket:didNotSendDataWithTag socketId: %u", _socketId);

    assert([_sendCallbacks count] != 0);
    void (^ callback)(BOOL, NSError*) = _sendCallbacks[0];
    assert(callback != nil);
    [_sendCallbacks removeObjectAtIndex:0];

    callback(NO, error);
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext
{
    VERBOSE_LOG(@"udbSocket:didReceiveData socketId: %u", _socketId);
    
    [_plugin fireReceiveEventsWithSocket: data:data address:[GCDAsyncUdpSocket hostFromAddress:address] port:[GCDAsyncUdpSocket portFromAddress:address]];
}

- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)sock withError:(NSError *)error
{
    VERBOSE_LOG(@"udbSocketDidClose:withError socketId: %u", _socketId);

    // Commented out assert, causes app to crash
    // when there is no network available.
    //assert(_closeCallback != nil);
    void (^callback)() = _closeCallback;
    _closeCallback = nil;
    
    // Check that callback is not nil before calling.
    if (callback != nil) {
        callback();
    } else if (error) {
        [_plugin fireReceiveErrorEventsWithSocket: error:error];
        [_plugin closeSocket: callbackId:nil];
    }
}
@end

@implementation ChromeSocketsUdp

- (void)pluginInitialize
{
    _socketId = 0;
    _receiveEventsCallbackId = nil;
}

- (void)onReset
{    
    [self closeSocket: callbackId:nil];    
}

- (NSDictionary*)buildErrorInfoWithErrorCode:(NSInteger)theErrorCode message:(NSString*)message
{
    return @{
        @"resultCode": [NSNumber numberWithInteger:theErrorCode],
        @"message": message,
    };
}

- (void)create:(CDVInvokedUrlCommand*)command
{
    NSDictionary* properties = [command argumentAtIndex:0];

    _socket = [[ChromeSocketsUdpSocket alloc] initWithId:_socketId plugin:self properties:properties];

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)bind:(CDVInvokedUrlCommand*)command
{
    NSString* address = [command argumentAtIndex:0];
    NSUInteger port = [[command argumentAtIndex:1] unsignedIntegerValue];

    if ([address isEqualToString:@"0.0.0.0"])
        address = nil;

    if (_socket == nil) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self buildErrorInfoWithErrorCode:ENOTSOCK message:@"Invalid Argument"]] callbackId:command.callbackId];
        return;
    }
    
    NSError* err;
    if ([_socket->_socket bindToPort:port interface:address error:&err]) {
        
        if (![_socket->_paused boolValue])
            [_socket->_socket beginReceiving:nil];
        
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    } else {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self buildErrorInfoWithErrorCode:[err code] message:[err localizedDescription]]] callbackId:command.callbackId];
    }
}

- (void)send:(CDVInvokedUrlCommand*)command
{
    NSString* address = [command argumentAtIndex:0];
    NSUInteger port = [[command argumentAtIndex:1] unsignedIntegerValue];
    NSData* data = [command argumentAtIndex:2];
   
    if (_socket == nil) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self buildErrorInfoWithErrorCode:ENOTSOCK message:@"Invalid Argument"]] callbackId:command.callbackId];
        return;
    }
  
    id<CDVCommandDelegate> commandDelegate = self.commandDelegate;
    [_socket->_sendCallbacks addObject:[^(BOOL success, NSError* error) {
        VERBOSE_LOG(@"ACK %@.%@ Write: %d", socketId, command.callbackId, success);

        if (success) {
            [commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:[data length]] callbackId:command.callbackId];
        } else {
            [commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self buildErrorInfoWithErrorCode:[error code] message:[error localizedDescription]]] callbackId:command.callbackId];
        }
    } copy]];

    [_socket->_socket sendData:data toHost:address port:port withTimeout:-1 tag:-1];
}

- (void)closeSocket: callbackId:(NSString*)theCallbackId
{
    if (_socket == nil)
        return;
  
    id<CDVCommandDelegate> commandDelegate = self.commandDelegate;
    _socket->_closeCallback = [^() {
        if (theCallbackId)
            [commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:theCallbackId];
        
        [_sockets removeObjectForKey:socketId];
    } copy];
   
    if ([_socket->_socket isClosed]) {
        void(^callback)() = _socket->_closeCallback;
        _socket->_closeCallback = nil;
        callback();
    } else {
        [_socket->_socket closeAfterSending];
    }
}

- (void)close:(CDVInvokedUrlCommand *)command
{
    [self closeSocket: callbackId:command.callbackId];
}

- (void)setBroadcast:(CDVInvokedUrlCommand *)command
{
    BOOL enabled = [[command argumentAtIndex:0] boolValue];
    
    if (_socket == nil) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self buildErrorInfoWithErrorCode:ENOTSOCK message:@"Invalid Argument"]] callbackId:command.callbackId];
        return;
    }
    
    NSError* err;
    if([_socket->_socket enableBroadcast:(enabled) error:&err]){
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    }else{
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self buildErrorInfoWithErrorCode:[err code] message:[err localizedDescription]]] callbackId:command.callbackId];
    }
}

- (void)registerReceiveEvents:(CDVInvokedUrlCommand*)command
{
    VERBOSE_LOG(@"registerReceiveEvents: ");
    _receiveEventsCallbackId = command.callbackId;
}

- (void)fireReceiveEventsWithSocket: data:(NSData*)theData address:(NSString*)theAddress port:(NSUInteger)thePort
{
    assert(_receiveEventsCallbackId != nil);

    NSArray *info = @[
        theData,
        theAddress,
        [NSNumber numberWithInteger:thePort],
    ];

    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsMultipart:info];
    [result setKeepCallbackAsBool:YES];

    [self.commandDelegate sendPluginResult:result callbackId:_receiveEventsCallbackId];
}

- (void)fireReceiveErrorEventsWithSocket: error:(NSError*)theError
{
    assert(_receiveEventsCallbackId != nil);
    
    NSDictionary* info = @{
        @"resultCode": [NSNumber numberWithUnsignedInt:[theError code]],
        @"message": [theError localizedDescription],
    };
    
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:info];
    [result setKeepCallbackAsBool:YES];
    
    [self.commandDelegate sendPluginResult:result callbackId:_receiveEventsCallbackId];
}
@end
