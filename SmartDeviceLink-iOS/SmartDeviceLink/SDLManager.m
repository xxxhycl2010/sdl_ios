//  SDLProxyBase.m
//  Copyright (c) 2015 Ford Motor Company. All rights reserved.

#import <Foundation/Foundation.h>
#import "SmartDeviceLink.h"
#import "SDLManager.h"
#import "SDLAddCommandWithHandler.h"
#import "SDLSubscribeButtonWithHandler.h"
#import "SDLSoftButtonWithHandler.h"
#import "SDLNotificationConstants.h"


@interface SDLManager () <SDLProxyListener>

// GCD
@property (strong, nonatomic) dispatch_queue_t backgroundQueue;
@property (strong, nonatomic) dispatch_queue_t mainUIQueue;
@property (strong, nonatomic) NSObject *delegateLock;
@property (strong, nonatomic) NSObject *proxyLock;
@property (strong, nonatomic) NSObject *correlationIdLock;
@property (strong, nonatomic) NSObject *hmiStateLock;
@property (strong, nonatomic) NSObject *rpcResponseHandlerMapLock;
@property (strong, nonatomic) NSObject *commandHandlerMapLock;
@property (strong, nonatomic) NSObject *buttonHandlerMapLock;
@property (strong, nonatomic) NSObject *customButtonHandlerMapLock;

// SDL state
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@property (strong, nonatomic) SDLProxy *proxy;
#pragma clang diagnostic pop

@property (assign, nonatomic) int correlationID;
@property (assign, nonatomic) BOOL firstHMIFullOccurred;
@property (assign, nonatomic) BOOL firstHMINotNoneOccurred;
@property (assign, getter=isConnected, nonatomic) BOOL connected;

// Dictionaries to link handlers with requests/commands/etc
@property (strong, nonatomic) NSMapTable *rpcResponseHandlerMap;
@property (strong, nonatomic) NSMutableDictionary<NSNumber *, SDLRPCRequest *> *rpcRequestDictionary;
@property (strong, nonatomic) NSMapTable *commandHandlerMap;
@property (strong, nonatomic) NSMapTable *buttonHandlerMap;
@property (strong, nonatomic) NSMapTable *customButtonHandlerMap;

@end

@implementation SDLManager


#pragma mark Lifecycle

+ (instancetype)sharedManager {
    static SDLManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[SDLManager alloc] init];
    });
    
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _delegateLock = [[NSObject alloc] init];
        _proxyLock = [[NSObject alloc] init];
        _correlationIdLock = [[NSObject alloc] init];
        _hmiStateLock = [[NSObject alloc] init];
        _rpcResponseHandlerMapLock = [[NSObject alloc] init];
        _commandHandlerMapLock = [[NSObject alloc] init];
        _buttonHandlerMapLock = [[NSObject alloc] init];
        _customButtonHandlerMapLock = [[NSObject alloc] init];
        _correlationID = 1;
        _connected = NO;
        _backgroundQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        _mainUIQueue = dispatch_get_main_queue();
        _firstHMIFullOccurred = NO;
        _firstHMINotNoneOccurred = NO;
        _rpcResponseHandlerMap = [NSMapTable mapTableWithKeyOptions:NSMapTableCopyIn valueOptions:NSMapTableCopyIn];
        _rpcRequestDictionary = [[NSMutableDictionary alloc] init];
        _commandHandlerMap = [NSMapTable mapTableWithKeyOptions:NSMapTableCopyIn valueOptions:NSMapTableCopyIn];
        _buttonHandlerMap = [NSMapTable mapTableWithKeyOptions:NSMapTableCopyIn valueOptions:NSMapTableCopyIn];
        _customButtonHandlerMap = [NSMapTable mapTableWithKeyOptions:NSMapTableCopyIn valueOptions:NSMapTableCopyIn];
        
    }
    return self;
}

- (void)postNotification:(NSString *)name info:(id)info {
    NSDictionary *userInfo = nil;
    if (info != nil) {
        userInfo = @{
                     SDLNotificationUserInfoNotificationObject: info
                    };
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:self userInfo:userInfo];
}


#pragma mark Exceptions

+ (NSException *)createMissingHandlerException {
    NSException* excep = [NSException
                          exceptionWithName:@"MissingHandlerException"
                          reason:@"This request requires a handler to be specified using the <RPC>WithHandler class"
                          userInfo:nil];
    return excep;
}

+ (NSException *)createMissingIDException {
    NSException* excep = [NSException
                          exceptionWithName:@"MissingIDException"
                          reason:@"This request requires an ID (command, softbutton, etc) to be specified"
                          userInfo:nil];
    return excep;
}

#pragma mark Event, Response, Notification Processing

- (void)notifyDelegatesOfEvent:(SDLEvent)sdlEvent error:(NSException *)error {
    // TODO: No need for weak/strong self
    dispatch_async(self.backgroundQueue, ^{
        switch (sdlEvent) {
            case SDLEventError: {
                [self onError:error];
            } break;
            case SDLEventClosed: {
                [self onProxyClosed];
            } break;
            case SDLEventOpened: {
                [self onProxyOpened];
            } break;
        }
    });
}

- (void)notifyDelegatesOfNotification:(SDLRPCNotification *)notification {
    dispatch_async(self.backgroundQueue, ^{
        
        if ([notification isKindOfClass:[SDLOnCommand class]]) {
            [self runHandlerForCommand:((SDLOnCommand *)notification)];
        }
        else if ([notification isKindOfClass:[SDLOnButtonPress class]]) {
            [self runHandlerForButton:((SDLRPCNotification *)notification)];
        }
        else if ([notification isKindOfClass:[SDLOnDriverDistraction class]]) {
            [self postNotification:SDLDidChangeDriverDistractionStateNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnAppInterfaceUnregistered class]]) {
            [self postNotification:SDLDidUnregisterNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnAudioPassThru class]]) {
            [self postNotification:SDLDidReceiveAudioPassThruNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnEncodedSyncPData class]]) {
            [self postNotification:SDLDidReceiveEncodedDataNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnHashChange class]]) {
            [self postNotification:SDLDidReceiveNewHashNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnLanguageChange class]]) {
            [self postNotification:SDLDidChangeLanguageNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnPermissionsChange class]]) {
            [self postNotification:SDLDidChangePermissionsNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnSyncPData class]]) {
            [self postNotification:SDLDidReceiveDataNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnSystemRequest class]]) {
            [self postNotification:SDLDidReceiveSystemRequestNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnTBTClientState class]]) {
            [self postNotification:SDLDidChangeTurnByTurnStateNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnTouchEvent class]]) {
            [self postNotification:SDLDidReceiveTouchEventNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnVehicleData class]]) {
            [self postNotification:SDLDidReceiveVehicleDataNotification info:notification];
        }
        else if ([notification isKindOfClass:[SDLOnLockScreenStatus class]]) {
            [self postNotification:SDLDidChangeLockScreenStatusNotification info:notification];
        }
    });
}

- (void)runHandlersForResponse:(SDLRPCResponse *)response {
    dispatch_async(self.backgroundQueue, ^{
        @synchronized(self.rpcResponseHandlerMapLock) {
            SDLRequestCompletionHandler handler = [self.rpcResponseHandlerMap objectForKey:response.correlationID];
            SDLRPCRequest *request = self.rpcRequestDictionary[response.correlationID];
            [self.rpcRequestDictionary removeObjectForKey:response.correlationID];
            [self.rpcResponseHandlerMap removeObjectForKey:response.correlationID];
            if (handler) {
                dispatch_async(self.mainUIQueue, ^{
                    handler(request, response, nil);
                });
            }
        }
        
        // Check for UnsubscribeButton, DeleteCommand and remove handlers
        if ([response isKindOfClass:[SDLDeleteCommandResponse class]]) {
            // TODO
            // The Command ID needs to be stored from the request RPC and then used here
        }
        else if ([response isKindOfClass:[SDLUnsubscribeButtonResponse class]]) {
            // TODO
        }
    });
}

- (void)runHandlerForCommand:(SDLOnCommand *)command {
    // Already background dispatched from caller
    SDLRPCNotificationHandler handler = nil;
    @synchronized(self.commandHandlerMapLock) {
        handler = [self.commandHandlerMap objectForKey:command.cmdID];
    }
    
    if (handler) {
        dispatch_async(self.mainUIQueue, ^{
            handler(command);
        });
    }
    
    // TODO: Should this even be a thing still?
    dispatch_async(self.mainUIQueue, ^{
        [self postNotification:SDLDidReceiveCommandNotification info:command];
    });
}

- (void)runHandlerForButton:(SDLRPCNotification *)notification {
    // Already background dispatched from caller
    SDLRPCNotificationHandler handler = nil;
    SDLButtonName *name = nil;
    NSNumber *customID = nil;
    
    if ([notification isKindOfClass:[SDLOnButtonEvent class]]) {
        name = ((SDLOnButtonEvent *)notification).buttonName;
        customID = ((SDLOnButtonEvent *)notification).customButtonID;
    }
    else if ([notification isKindOfClass:[SDLOnButtonPress class]]) {
        name = ((SDLOnButtonPress *)notification).buttonName;
        customID = ((SDLOnButtonPress *)notification).customButtonID;
    }
    
    if ([name isEqual:[SDLButtonName CUSTOM_BUTTON]]) {
        @synchronized(self.customButtonHandlerMapLock) {
            handler = [self.customButtonHandlerMap objectForKey:customID];
        }
    }
    else {
        @synchronized(self.buttonHandlerMapLock) {
            handler = [self.buttonHandlerMap objectForKey:name.value];
        }
    }
    
    if (handler) {
        dispatch_async(self.mainUIQueue, ^{
            handler(notification);
        });
    }
    
    // TODO: Should this even be a thing still?
    if ([notification isKindOfClass:[SDLOnButtonEvent class]]) {
        dispatch_async(self.mainUIQueue, ^{
            [self postNotification:SDLDidReceiveButtonEventNotification info:notification];
        });
    }
    else if ([notification isKindOfClass:[SDLOnButtonPress class]]) {
        dispatch_async(self.mainUIQueue, ^{
            [self postNotification:SDLDidReceiveButtonPressNotification info:notification];
        });
    }
}


#pragma mark SDLProxyBase
// typedef void (^SDLRequestCompletionHandler) (__kindof SDLRPCRequest *request, __kindof SDLRPCResponse *response, NSError *error);

- (void)sendRequest:(SDLRPCRequest *)request withCompletionHandler:(SDLRequestCompletionHandler)handler {
    if (!self.isConnected) {
        [SDLDebugTool logInfo:@"Proxy not connected! Not sending RPC."];
        handler(nil, nil, [SDLManager errorWithDescription:@"Can't send request" andReason:@"Proxy not connected"]);
        return;
    }
    // Add a correlation ID
    NSNumber *corrID = [self getNextCorrelationId];
    request.correlationID = corrID;
    
    // Check for RPCs that require an extra handler
    // TODO: add SDLAlert and SDLScrollableMessage
    if ([request isKindOfClass:[SDLShow class]]) {
        SDLShow *show = (SDLShow *)request;
        NSMutableArray *softButtons = show.softButtons;
        if (softButtons && softButtons.count > 0) {
            for (SDLSoftButton *sb in softButtons) {
                if (![sb isKindOfClass:[SDLSoftButtonWithHandler class]] || ((SDLSoftButtonWithHandler *)sb).onButtonHandler == nil) {
                    @throw [SDLManager createMissingHandlerException];
                }
                if (!sb.softButtonID) {
                    @throw [SDLManager createMissingIDException];
                }
                    [self.customButtonHandlerMap setObject:((SDLSoftButtonWithHandler *)sb).onButtonHandler forKey:sb.softButtonID];
            }
        }
    }
    else if ([request isKindOfClass:[SDLAddCommand class]]) {
        if (![request isKindOfClass:[SDLAddCommandWithHandler class]] || ((SDLAddCommandWithHandler *)request).onCommandHandler == nil) {
            @throw [SDLManager createMissingHandlerException];
        }
        if (!((SDLAddCommandWithHandler *)request).cmdID) {
            @throw [SDLManager createMissingIDException];
        }
            [self.commandHandlerMap setObject:((SDLAddCommandWithHandler *)request).onCommandHandler forKey:((SDLAddCommandWithHandler *)request).cmdID];
    }
    else if ([request isKindOfClass:[SDLSubscribeButton class]]) {
        if (![request isKindOfClass:[SDLSubscribeButtonWithHandler class]] || ((SDLSubscribeButtonWithHandler *)request).onButtonHandler == nil) {
            @throw [SDLManager createMissingHandlerException];
        }
        // Convert SDLButtonName to NSString, since it doesn't conform to <NSCopying>
        NSString *buttonName = ((SDLSubscribeButtonWithHandler *)request).buttonName.value;
        if (!buttonName) {
            @throw [SDLManager createMissingIDException];
        }
            [self.buttonHandlerMap setObject:((SDLSubscribeButtonWithHandler *)request).onButtonHandler forKey:buttonName];
    }
    
    if (handler) {
        self.rpcRequestDictionary[corrID] = request;
        [self.rpcResponseHandlerMap setObject:handler forKey:corrID];
    }
    [self.proxy sendRPC:request];
}

- (void)startProxyWithAppName:(NSString *)appName appID:(NSString *)appID isMedia:(BOOL)isMedia languageDesired:(SDLLanguage *)languageDesired {
    // TODO: No need for strong/weak self
    dispatch_async(self.backgroundQueue, ^{
        // TODO: Use non-null for these
        if (appName && appID && languageDesired)
        {
            [SDLDebugTool logInfo:@"Start Proxy"];
            self.appName = appName;
            self.appID = appID;
            self.isMedia = isMedia;
            self.languageDesired = languageDesired;
            @synchronized(self.proxyLock) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [SDLProxy enableSiphonDebug];
                self.proxy = [SDLProxyFactory buildSDLProxyWithListener:self];
            }
#pragma clang diagnostic pop
        }
        else {
            [SDLDebugTool logInfo:@"Error: One or more parameters (appName, appID, languageDesired) is nil"];
        }
    });
}

- (void)startProxy {
    [self startProxyWithAppName:self.appName appID:self.appID isMedia:self.isMedia languageDesired:self.languageDesired];
}

- (void)stopProxy {
    dispatch_async(self.backgroundQueue, ^{
        [self disposeProxy];
    });
}

- (void)putFileStream:(NSInputStream *)inputStream withRequest:(SDLPutFile *)putFileRPCRequest {
    dispatch_async(self.backgroundQueue, ^{
        // Add a correlation ID
        SDLRPCRequest *rpcWithCorrID = putFileRPCRequest;
        NSNumber *corrID = [self getNextCorrelationId];
        rpcWithCorrID.correlationID = corrID;
        
        @synchronized(self.proxyLock) {
            [self.proxy putFileStream:inputStream withRequest:(SDLPutFile *)rpcWithCorrID];
        }
    });
}


#pragma mark Private Methods

// TODO: Private methods should be prefixed `sdl_`
- (void)disposeProxy {
    [SDLDebugTool logInfo:@"Stop Proxy"];
    @synchronized(self.proxyLock) {
        [self.proxy dispose];
        self.proxy = nil;
    }
    @synchronized(self.hmiStateLock) {
        self.firstHMIFullOccurred = NO;
        self.firstHMINotNoneOccurred = NO;
    }
}

- (NSNumber *)getNextCorrelationId {
    NSNumber *corrId = nil;
    @synchronized(self.correlationIdLock) {
        self.correlationID++;
        corrId = [NSNumber numberWithInt:self.correlationID];
    }
    return corrId;
}


#pragma mark - SDLProxyListener Methods

- (void)onProxyOpened {
    [SDLDebugTool logInfo:@"onProxyOpened"];
    dispatch_async(self.backgroundQueue, ^{
        @autoreleasepool {
            self.connected = YES;
            
            SDLRegisterAppInterface *regRequest = [SDLRPCRequestFactory buildRegisterAppInterfaceWithAppName:self.appName languageDesired:self.languageDesired appID:self.appID];
            regRequest.isMediaApplication = [NSNumber numberWithBool:self.isMedia];
            regRequest.ngnMediaScreenAppName = self.shortName;
            
            if (self.vrSynonyms) {
                regRequest.vrSynonyms = [NSMutableArray arrayWithArray:self.vrSynonyms];
            }
            // TODO: implement handler with success/error
            [self sendRequest:regRequest withCompletionHandler:^(__kindof SDLRPCRequest *request, __kindof SDLRPCResponse *response, NSError *error) {
                __block NSString *info = response.info;
                if (!response.success) {
                    dispatch_async(self.mainUIQueue, ^{
                        NSError *error = [SDLManager errorWithDescription:@"Failed to register" andReason:info];
                        [self postNotification:SDLDidFailToRegisterNotification info:error];
                    });
                }
                else {
                    dispatch_async(self.mainUIQueue, ^{
                        [self postNotification:SDLDidRegisterNotification info:response];
                    });
                }

            }];
        }
    });
    dispatch_async(self.mainUIQueue, ^{
        [self postNotification:SDLDidConnectNotification info:nil];
    });
}

- (void)onProxyClosed {
    dispatch_async(self.backgroundQueue, ^{
        // Already background dispatched from caller
        [SDLDebugTool logInfo:@"onProxyClosed"];
        self.connected = NO;
        [self disposeProxy];    // call this method instead of stopProxy to avoid double-dispatching
        dispatch_async(self.mainUIQueue, ^{
            [self postNotification:SDLDidDisconnectNotification info:nil];
        });
        [self startProxy];
    });
}

- (void)onError:(NSException *)e {
    dispatch_async(self.mainUIQueue, ^{
        NSError *error = [SDLManager errorWithDescription:e.name andReason:e.reason];
        [self postNotification:SDLDidReceiveErrorNotification info:error];
    });
}

- (void)onAddCommandResponse:(SDLAddCommandResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)(SDLRPCResponse *)response];
}

- (void)onAddSubMenuResponse:(SDLAddSubMenuResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onAlertResponse:(SDLAlertResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onChangeRegistrationResponse:(SDLChangeRegistrationResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onCreateInteractionChoiceSetResponse:(SDLCreateInteractionChoiceSetResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onDeleteCommandResponse:(SDLDeleteCommandResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onDeleteFileResponse:(SDLDeleteFileResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onDeleteInteractionChoiceSetResponse:(SDLDeleteInteractionChoiceSetResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onDeleteSubMenuResponse:(SDLDeleteSubMenuResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onDiagnosticMessageResponse:(SDLDiagnosticMessageResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onEncodedSyncPDataRespons:(SDLEncodedSyncPDataResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onEndAudioPassThruResponse:(SDLEndAudioPassThruResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onGenericResponse:(SDLGenericResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onGetDTCsResponse:(SDLGetDTCsResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onGetVehicleDataResponse:(SDLGetVehicleDataResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onListFilesResponse:(SDLListFilesResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onPerformAudioPassThruResponse:(SDLPerformAudioPassThruResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onPerformInteractionResponse:(SDLPerformInteractionResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onPutFileResponse:(SDLPutFileResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onReadDIDResponse:(SDLReadDIDResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onRegisterAppInterfaceResponse:(SDLRegisterAppInterfaceResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onResetGlobalPropertiesResponse:(SDLResetGlobalPropertiesResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onScrollableMessageResponse:(SDLScrollableMessageResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSetAppIconResponse:(SDLSetAppIconResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSetDisplayLayoutResponse:(SDLSetDisplayLayoutResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSetGlobalPropertiesResponse:(SDLSetGlobalPropertiesResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSetMediaClockTimerResponse:(SDLSetMediaClockTimerResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onShowConstantTBTResponse:(SDLShowConstantTBTResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onShowResponse:(SDLShowResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSliderResponse:(SDLSliderResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSpeakResponse:(SDLSpeakResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSubscribeButtonResponse:(SDLSubscribeButtonResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSubscribeVehicleDataResponse:(SDLSubscribeVehicleDataResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onSyncPDataResponse:(SDLSyncPDataResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onUpdateTurnListResponse:(SDLUpdateTurnListResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onUnregisterAppInterfaceResponse:(SDLUnregisterAppInterfaceResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onUnsubscribeButtonResponse:(SDLUnsubscribeButtonResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onUnsubscribeVehicleDataResponse:(SDLUnsubscribeVehicleDataResponse *)response {
    [self runHandlersForResponse:(SDLRPCResponse *)response];
}

- (void)onOnLockScreenNotification:(SDLLockScreenStatus *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnHMIStatus:(SDLOnHMIStatus *)notification {
    dispatch_async(self.backgroundQueue, ^{
        [SDLDebugTool logInfo:@"onOnHMIStatus"];
        if (notification.hmiLevel == [SDLHMILevel FULL])
        {
            BOOL occurred = NO;
            @synchronized(self.hmiStateLock) {
                occurred = self.firstHMINotNoneOccurred;
            }
            if (!occurred)
            {
                dispatch_async(self.mainUIQueue, ^{
                    [self postNotification:SDLDidReceiveFirstNonNoneHMIStatusNotification info:notification];
                });
            }
            @synchronized(self.hmiStateLock) {
                self.firstHMINotNoneOccurred = YES;
            }
            
            @synchronized(self.hmiStateLock) {
                occurred = self.firstHMIFullOccurred;
            }
            if (!occurred)
            {
                dispatch_async(self.mainUIQueue, ^{
                    [self postNotification:SDLDidReceiveFirstFullHMIStatusNotification info:notification];
                });
            }
            @synchronized(self.hmiStateLock) {
                self.firstHMIFullOccurred = YES;
            }
        }
        else if (notification.hmiLevel == [SDLHMILevel BACKGROUND] || notification.hmiLevel == [SDLHMILevel LIMITED])
        {
            BOOL occurred = NO;
            @synchronized(self.hmiStateLock) {
                occurred = self.firstHMINotNoneOccurred;
            }
            if (!occurred)
            {
                dispatch_async(self.mainUIQueue, ^{
                    [self postNotification:SDLDidReceiveFirstNonNoneHMIStatusNotification info:notification];
                });
            }
            @synchronized(self.hmiStateLock) {
                self.firstHMINotNoneOccurred = YES;
            }
        }
        dispatch_async(self.mainUIQueue, ^{
            [self postNotification:SDLDidChangeHMIStatusNotification info:notification];
        });
    });
}

- (void)onOnDriverDistraction:(SDLOnDriverDistraction *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnAppInterfaceUnregistered:(SDLOnAppInterfaceUnregistered *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnAudioPassThru:(SDLOnAudioPassThru *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnButtonEvent:(SDLOnButtonEvent *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnButtonPress:(SDLOnButtonPress *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnCommand:(SDLOnCommand *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnEncodedSyncPData:(SDLOnEncodedSyncPData *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnHashChange:(SDLOnHashChange *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnLanguageChange:(SDLOnLanguageChange *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnPermissionsChange:(SDLOnPermissionsChange *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnSyncPData:(SDLOnSyncPData *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnSystemRequest:(SDLOnSystemRequest *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnTBTClientState:(SDLOnTBTClientState *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnTouchEvent:(SDLOnTouchEvent *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

- (void)onOnVehicleData:(SDLOnVehicleData *)notification {
    [self notifyDelegatesOfNotification:(SDLRPCNotification *)notification];
}

#pragma mark class methods

+ (NSError *)errorWithDescription:(NSString *)description andReason:(NSString *)reason {
    NSDictionary *userInfo = @{
                               NSLocalizedDescriptionKey: NSLocalizedString(description, nil),
                               NSLocalizedFailureReasonErrorKey: NSLocalizedString(reason, nil),
                               NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Have you tried turning it off and on again?", nil)
                               };
    return [NSError errorWithDomain:@"com.smartdevicelink.error"
                               code:-1
                           userInfo:userInfo];
}


@end