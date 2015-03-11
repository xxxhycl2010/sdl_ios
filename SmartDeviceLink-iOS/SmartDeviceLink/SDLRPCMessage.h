//  SDLRPCMessage.h
//



#import "SDLEnum.h"

@interface SDLRPCStruct : NSObject {
	NSMutableDictionary* store;
}

-(instancetype) initWithDictionary:(NSMutableDictionary*) dict;
-(instancetype) init;

-(NSMutableDictionary*) serializeAsDictionary:(Byte) version;

@end

@interface SDLRPCMessage : SDLRPCStruct {
	NSMutableDictionary* function;
	NSMutableDictionary* parameters;
	NSString* messageType;
}

-(instancetype) initWithName:(NSString*) name;
-(instancetype) initWithDictionary:(NSMutableDictionary*) dict;
-(NSString*) getFunctionName;
-(void) setFunctionName:(NSString*) functionName;
-(NSObject*) getParameters:(NSString*) functionName;
-(void) setParameters:(NSString*) functionName value:(NSObject*) value;

@property(strong) NSData* bulkData;
@property(strong, readonly) NSString* name;
@property(strong, readonly) NSString* messageType;

@end