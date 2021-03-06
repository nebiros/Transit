//
//  Transit.m
//  TransitTestsIOS
//
//  Created by Heiko Behrens on 08.02.13.
//  Copyright (c) 2013 BeamApp. All rights reserved.
//

#import "Transit.h"
#import "Transit+Private.h"
#import "SBJson.h"
#import "SBJsonStreamWriterAccumulator.h"
#import "SBJsonStreamWriterState.h"
#import <objc/runtime.h>


#pragma mark - extract from CTObjectiveCRuntimeAdditions

//
//  TransitCTBlock* has originally been developed by
//  Copyright (c) 2012 olettere
//
//  Find the code at
//  https://github.com/ebf/CTObjectiveCRuntimeAdditions
//

struct TransitCTBlockLiteral {
    void *isa; // initialized to &_NSConcreteStackBlock or &_NSConcreteGlobalBlock
    int flags;
    int reserved;
    void (*invoke)(void *, ...);
    struct block_descriptor {
        unsigned long int reserved;	// NULL
        unsigned long int size;         // sizeof(struct Block_literal_1)
        // optional helper functions
        void (*copy_helper)(void *dst, void *src);     // IFF (1<<25)
        void (*dispose_helper)(void *src);             // IFF (1<<25)
        // required ABI.2010.3.16
        const char *signature;                         // IFF (1<<30)
    } *descriptor;
    // imported variables
};

enum {
    TransitCTBlockDescriptionFlagsHasCopyDispose = (1 << 25),
    TransitCTBlockDescriptionFlagsHasCtor = (1 << 26), // helpers have C++ code
    TransitCTBlockDescriptionFlagsIsGlobal = (1 << 28),
    TransitCTBlockDescriptionFlagsHasStret = (1 << 29), // IFF BLOCK_HAS_SIGNATURE
    TransitCTBlockDescriptionFlagsHasSignature = (1 << 30)
};
typedef int TransitCTBlockDescriptionFlags;

@interface TransitCTBlockDescription : NSObject

@property (nonatomic, readonly) TransitCTBlockDescriptionFlags flags;
@property (nonatomic, readonly) NSMethodSignature *blockSignature;
@property (nonatomic, readonly) unsigned long int size;
@property (nonatomic, readonly) id block;

- (id)initWithBlock:(id)block;

@end

@interface NSInvocation (PrivateHack)
- (void)invokeUsingIMP: (IMP)imp;
@end



@implementation TransitCTBlockDescription

- (id)initWithBlock:(id)block
{
    if (self = [super init]) {
        _block = block;

        struct TransitCTBlockLiteral *blockRef = (__bridge struct TransitCTBlockLiteral *)block;
        _flags = blockRef->flags;
        _size = blockRef->descriptor->size;

        if (_flags & TransitCTBlockDescriptionFlagsHasSignature) {
            void *signatureLocation = blockRef->descriptor;
            signatureLocation += sizeof(unsigned long int);
            signatureLocation += sizeof(unsigned long int);

            if (_flags & TransitCTBlockDescriptionFlagsHasCopyDispose) {
                signatureLocation += sizeof(void(*)(void *dst, void *src));
                signatureLocation += sizeof(void (*)(void *src));
            }

            const char *signature = (*(const char **)signatureLocation);
            _blockSignature = [NSMethodSignature signatureWithObjCTypes:signature];
        }
    }
    return self;
}

@end

#pragma mark - Transit Basics

BOOL transit_iOS_7_OrLater() {
#if TRANSIT_OS_IOS
    return ([UIDevice.currentDevice.systemVersion compare:@"7" options:NSNumericSearch]) > NSOrderedAscending;
#else
    return NO;
#endif
}

BOOL transit_iOS_6_OrLater() {
#if TRANSIT_OS_IOS
    return ([UIDevice.currentDevice.systemVersion compare:@"6" options:NSNumericSearch]) > NSOrderedAscending;
#else
    return NO;
#endif
}

BOOL transit_OSX_min_version(NSString *minVersion){
#if TRANSIT_OS_MAC
    SInt32 major, minor;
    Gestalt(gestaltSystemVersionMajor, &major);
    Gestalt(gestaltSystemVersionMinor, &minor);
    NSString* version = [NSString stringWithFormat:@"%d.%d", major, minor];
    return [version compare:minVersion options:NSNumericSearch] > NSOrderedAscending;
#else
    return NO;
#endif
}

BOOL transit_OSX_10_8_OrLater() {
    return transit_OSX_min_version(@"10.8");
}

BOOL transit_OSX_10_9_OrLater(){
    return transit_OSX_min_version(@"10.9");
}


BOOL transit_specificBlocksSupported() {
#if TRANSIT_OS_IOS
    return transit_iOS_6_OrLater();
#endif
#if TRANSIT_OS_MAC
    return transit_OSX_10_8_OrLater();
#endif
    return NO;
}

void * _TRANSIT_ASSOC_KEY_IS_JS_EXPRESSION = &_TRANSIT_ASSOC_KEY_IS_JS_EXPRESSION;

NSString* transit_stringAsJSExpression(NSString* self) {
    if(transit_isJSExpression(self))
        return self;
    
    NSString *result = [NSString stringWithFormat:@"%@", self];
    objc_setAssociatedObject(result, _TRANSIT_ASSOC_KEY_IS_JS_EXPRESSION, [NSNumber numberWithBool:YES], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

BOOL transit_isJSExpression(NSString* self) {
    id assoc = objc_getAssociatedObject(self, _TRANSIT_ASSOC_KEY_IS_JS_EXPRESSION);
    return [assoc boolValue];
}

id TransitNilSafe(id valueOrNil) {
    return valueOrNil ? valueOrNil : transit_stringAsJSExpression(@"undefined");
}

@implementation NSString(TransRegExp)

-(NSString*)transit_stringByReplacingMatchesOf:(NSRegularExpression *)regex withTransformation:(NSString*(^)(NSString*element)) block {

    NSMutableString* mutableString = [self mutableCopy];
    NSInteger offset = 0;

    for (NSTextCheckingResult* result in [regex matchesInString:self options:0 range:NSMakeRange(0, self.length)]) {
        
        NSRange resultRange = [result range];
        resultRange.location += offset;
        
        NSString* match = [regex replacementStringForResult:result
                                                   inString:mutableString
                                                     offset:offset
                                                   template:@"$0"];

        NSString* replacement = block(match);
        
        // make the replacement
        [mutableString replaceCharactersInRange:resultRange withString:replacement];
        
        // update the offset based on the replacement
        offset += ([replacement length] - resultRange.length);
    }
    return mutableString;
}

@end

@interface TransitJSRepresentationStreamWriter : SBJsonStreamWriter

@property (nonatomic, unsafe_unretained) SBJsonStreamWriterState *state; // Internal
@property(nonatomic, strong) NSMutableOrderedSet* proxiesOnScope;

@end

@implementation TransitJSRepresentationStreamWriter

-(BOOL)writeValue:(id)value {
    // nil -> undefined
    if(value == nil)
        return [self writeJSExpression:@"undefined"];
    
    // NSString marked as jsExpression -> jsEpxression
    if([value isKindOfClass:NSString.class] && transit_isJSExpression(value))
        return [self writeJSExpression:value];
    
    // TransitProxy -> must provide own representation
    if([value isKindOfClass:TransitProxy.class]) {
        TransitProxy* proxy = (TransitProxy*)value;
        NSString* jsRepresentation = [proxy _jsRepresentationCollectingProxiesOnScope:self.proxiesOnScope];
        if(jsRepresentation == nil) {
            self.error = [NSString stringWithFormat:@"TransitProxy %@ has no jsRepresentation", value];
            return NO;
        }
        
        return [self writeJSExpression:jsRepresentation];
    }
    // NSError -> new Error(desc)
    if([value isKindOfClass:NSError.class]) {
        NSString* desc = [value userInfo][NSLocalizedDescriptionKey];
        NSString* jsExpression = [NSString stringWithFormat:@"new Error(%@)", [TransitProxy jsRepresentation:desc collectingProxiesOnScope:self.proxiesOnScope]];
        return [self writeJSExpression:jsExpression];
    }
    
    // any valid JSON value
    return [super writeValue:value];
}

-(BOOL)writeJSExpression:(NSString*)jsExpression {
	if ([self.state isInvalidState:self]) return NO;
	if ([self.state expectingKey:self]) return NO;
	[self.state appendSeparator:self];
	if (self.humanReadable) [self.state appendWhitespace:self];
    
	NSData *data = [jsExpression dataUsingEncoding:NSUTF8StringEncoding];
    [self.delegate writer:self appendBytes:data.bytes length:data.length];

	[self.state transitionState:self];
	return YES;
}

@end

NSError*transit_errorWithCodeFromException(NSUInteger code, NSException* exception) {
    NSString *desc = exception.userInfo[NSLocalizedDescriptionKey] ? exception.userInfo[NSLocalizedDescriptionKey] : [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason];
    return [NSError errorWithDomain:@"transit" code:code userInfo:@{NSLocalizedDescriptionKey: desc}];
}

@implementation TransitObject{
    __weak TransitContext*_context;
}

-(id)initWithContext:(TransitContext*)context {
    self = [self init];
    if(self) {
        _context = context;
    }
    return self;
}

-(TransitContext*)context {
    return _context;
}

- (void)clearContext {
    _context = nil;
}

- (id)objectForImplicitVars {
    return self;
}

- (id)objectForKey:(id)key{
    return [self.context eval:@"@[@]" val:self.objectForImplicitVars val:key];
}

- (void)setObject:(id)object forKey:(id < NSCopying >)key {
    [self.context eval:@"@[@]=@" val:self.objectForImplicitVars val:key val:object];
}

- (id)objectAtIndexedSubscript:(NSUInteger)idx {
    return [self objectForKey:@(idx)];
}

- (void)setObject:(id)obj atIndexedSubscript:(NSInteger)idx {
    [self setObject:obj forKey:@(idx)];
}

- (id)objectForKeyedSubscript:(id)key {
    return [self objectForKey:key];
}

- (void)setObject:(id)obj forKeyedSubscript:(id <NSCopying>)key {
    [self setObject:obj forKey:key];
}

- (id)callMember:(NSString *)string {
    return [self callMember:string arguments:@[]];
}

- (id)callMember:(NSString *)string arg:(id)arg0 {
    return [self callMember:string arguments:@[arg0]];
}

- (id)callMember:(NSString *)string arg:(id)arg0 arg:(id)arg1 {
    return [self callMember:string arguments:@[arg0, arg1]];
}

- (id)callMember:(NSString *)string arg:(id)arg0 arg:(id)arg1 arg:(id)arg2 {
    return [self callMember:string arguments:@[arg0, arg1, arg2]];
}

- (id)callMember:(NSString *)string arguments:(NSArray *)arguments {
    return [self.context eval:@"@[@].apply(@,@)" values:@[self, string, self, arguments]];
}

@end

@implementation TransitProxy {
    NSString* _proxyId;
    id _value;
}

-(id)initWithContext:(TransitContext *)context proxyId:(NSString*)proxyId {
    self = [super initWithContext:context];
    if(self) {
        _proxyId = proxyId;
    }
    return self;
}

-(id)initWithContext:(TransitContext *)context value:(id)value {
    self = [super initWithContext:context];
    if(self){
        _value = value;
    }
    return self;
}

-(id)initWitContext:(TransitContext *)context jsRepresentation:(NSString*)jsRepresentation {
    return [self initWithContext:context value:transit_stringAsJSExpression(jsRepresentation)];
}


-(id)initWithContext:(TransitContext*)context {
    return [self initWithContext:context proxyId:nil];
}

-(void)dealloc {
    [self dispose];
}

-(BOOL)disposed {
    return self.context == nil;
}

-(void)clearContextAndProxyId {
    [self clearContext];
    _proxyId = nil;
}

-(void)dispose {
    if(self.context) {
        if(_proxyId){
            [self.context releaseJSProxyWithId:_proxyId];
        }
        [self clearContextAndProxyId];
    }
}

-(NSString*)proxyId {
    return _proxyId;
}

-(NSString*)jsRepresentationToResolveProxy {
    if(_proxyId && self.context)
        return [self.context jsRepresentationToResolveProxyWithId:_proxyId];
    
    @throw [NSException exceptionWithName:@"TransitException" reason:@"Internal Error: Proxy cannot be resolved" userInfo:nil];
}

-(NSString*)_jsRepresentationCollectingProxiesOnScope:(NSMutableOrderedSet*)proxiesOnScope {
    if(_proxyId && self.context) {
        [proxiesOnScope addObject:self];
        return [self.context jsRepresentationForProxyWithId:_proxyId];
    }
    
    if(_value) {
        return [self.class jsRepresentation:_value collectingProxiesOnScope:proxiesOnScope];
    }
    
    return nil;
}

+(NSString*)jsRepresentation:(id)object collectingProxiesOnScope:(NSMutableOrderedSet*)proxiesOnScope {
    SBJsonStreamWriterAccumulator *accumulator = [[SBJsonStreamWriterAccumulator alloc] init];
    
	TransitJSRepresentationStreamWriter *streamWriter = [[TransitJSRepresentationStreamWriter alloc] init];
    streamWriter.delegate = accumulator;
    streamWriter.proxiesOnScope = proxiesOnScope;
    
    BOOL ok = [streamWriter writeValue:object];
    if(!ok) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"cannot be represented as JS (%@): %@", streamWriter.error, object] userInfo:nil];
    }
    
    return [NSString.alloc initWithData:accumulator.data encoding:NSUTF8StringEncoding];
}

+(NSString*)jsRepresentationFromCode:(NSString *)jsCode arguments:(NSArray *)arguments collectingProxiesOnScope:(NSMutableOrderedSet*)proxiesOnScope {
    if(transit_isJSExpression(jsCode)) {
        if(arguments.count > 0)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"jsExpression cannot take any additional arguments" userInfo:nil];
        return jsCode;
    }
    
    NSError* error;
    NSRegularExpression *regex = [NSRegularExpression
                                  regularExpressionWithPattern:@"@"
                                  options:(NSRegularExpressionOptions) 0
                                  error:&error];
    
    NSMutableArray* mutableArguments = [arguments mutableCopy];
    jsCode = [jsCode transit_stringByReplacingMatchesOf:regex withTransformation:^(NSString *match) {
        if (mutableArguments.count <= 0)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"too few arguments" userInfo:nil];

        id elem = mutableArguments[0];
        NSString *jsRepresentation = [self jsRepresentation:elem collectingProxiesOnScope:proxiesOnScope];
        NSString *result = [NSString stringWithFormat:@"%@", jsRepresentation];

        [mutableArguments removeObjectAtIndex:0];
        return result;
    }];
    
    if(mutableArguments.count >0)
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"too many arguments" userInfo:nil];
    
    return transit_stringAsJSExpression(jsCode);
}

@end

@implementation TransitEvaluable : TransitObject

-(id)eval:(NSString*)jsCode {
    return [self eval:jsCode thisArg:self values:@[] returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode val:(id)val0 {
    return [self eval:jsCode thisArg:self values:@[TransitNilSafe(val0)] returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode val:(id)val0 val:(id)val1 {
    return [self eval:jsCode thisArg:self values:@[TransitNilSafe(val0), TransitNilSafe(val1)] returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode val:(id)val0 val:(id)val1 val:(id)val2 {
    return [self eval:jsCode thisArg:self values:@[TransitNilSafe(val0), TransitNilSafe(val1), TransitNilSafe(val2)] returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode values:(NSArray*)values {
    return [self eval:jsCode thisArg:self values:values returnJSResult:YES];
}

-(id)eval:(NSString*)jsCode thisArg:(id)thisArg {
    return [self eval:jsCode thisArg:thisArg values:@[] returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode thisArg:(id)thisArg val:(id)val0 {
    return [self eval:jsCode thisArg:thisArg values:@[TransitNilSafe(val0)] returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode thisArg:(id)thisArg val:(id)val0 val:(id)val1 {
    return [self eval:jsCode thisArg:thisArg values:@[TransitNilSafe(val0), TransitNilSafe(val1)] returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode thisArg:(id)thisArg values:(NSArray*)values {
    return [self eval:jsCode thisArg:thisArg values:values returnJSResult:YES];
}

-(id)eval:(NSString *)jsCode thisArg:(id)thisArg values:(NSArray *)values returnJSResult:(BOOL)returnJSResult {
    return [self.context eval:jsCode thisArg:thisArg values:values returnJSResult:returnJSResult];
}

@end

@implementation TransitCurrentCall

TransitContext *_TransitCurrentCall_currentContext;
TransitFunction *_TransitCurrentCall_originalFunctionForCurrentCall;

+(TransitContext *)context {
    return _TransitCurrentCall_currentContext;
}

+(TransitFunctionCallScope *)callScope {
    TransitFunctionCallScope *scope = (TransitFunctionCallScope *) self.context.currentCallScope;
    if(scope && ![scope isKindOfClass:TransitFunctionCallScope.class])
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"currentCallScope is not a TransitFunctionCallScope: %@", scope] userInfo:nil];
    return scope;
}

+(id)thisArg {
    return [self.callScope.thisArg copy];
}

+(NSArray*)arguments {
    return self.callScope.arguments;
}

+ (TransitFunction *)replacedFunction {
    return _TransitCurrentCall_originalFunctionForCurrentCall;
}

+(id)forwardToReplacedFunction {
    return [self.callScope forwardToFunction:self.replacedFunction];
}

@end


NSUInteger _TRANSIT_CONTEXT_LIVING_INSTANCE_COUNT = 0;
NSUInteger _TRANSIT_DRAIN_JS_PROXIES_THRESHOLD = 250;
CGFloat _TRANSIT_ASYNC_CALL_DELAY = 0.01;
NSString* _TRANSIT_MARKER_PREFIX_JS_FUNCTION_ = @"__TRANSIT_JS_FUNCTION_";
NSString* _TRANSIT_MARKER_PREFIX_OBJECT_PROXY_ = @"__TRANSIT_OBJECT_PROXY_";
NSString* _TRANSIT_MARKER_GLOBAL_OBJECT = @"__TRANSIT_OBJECT_GLOBAL";

NSString* _TRANSIT_MARKER_PREFIX_NATIVE_FUNCTION = @"__TRANSIT_NATIVE_FUNCTION_";
NSUInteger _TRANSIT_MARKER_PREFIX_MIN_LEN = 12;

@implementation TransitContext {
    NSMutableDictionary* _retainedNativeProxies;
    int _lastNativeFunctionId;
    NSMutableArray* _jsProxiesToBeReleased;
    NSString* _transitGlobalVarJSRepresentation;
    NSMutableArray* _queuedAsyncCallsToJSFunctions;
}

-(id)init {
    self = [super init];
    if(self){
        _TRANSIT_CONTEXT_LIVING_INSTANCE_COUNT++;
        _retainedNativeProxies = [NSMutableDictionary dictionary];
        _jsProxiesToBeReleased = [NSMutableArray array];
        _transitGlobalVarJSRepresentation = transit_stringAsJSExpression(@"transit");
        _queuedAsyncCallsToJSFunctions = [NSMutableArray array];
    }
    return self;
}

-(void)dealloc {
    // dispose manually from here to maintain correct life cycle
    [self disposeAllNativeProxies];
    _TRANSIT_CONTEXT_LIVING_INSTANCE_COUNT--;
}

-(void)dispose {
    [self disposeAllNativeProxies];
}

-(TransitContext*)context {
    return self;
}

-(id)objectForImplicitVars {
    return transit_stringAsJSExpression(@"window");
}

-(NSString*)jsRepresentationForProxyWithId:(NSString*)proxyId {
    return proxyId;
}

-(NSString*)jsRepresentationToResolveProxyWithId:(NSString*)proxyId {
    return transit_stringAsJSExpression([NSString stringWithFormat:@"%@.r(\"%@\")", self.transitGlobalVarJSRepresentation, proxyId]);
}

-(NSString*)jsRepresentationForNativeFunctionWithId:(NSString*)proxyId {
    return [NSString stringWithFormat:@"%@%@", _TRANSIT_MARKER_PREFIX_NATIVE_FUNCTION, proxyId];
}

-(NSString*)jsRepresentationToResolveNativeFunctionWithId:(NSString*)proxyId async:(BOOL)async noThis:(BOOL)noThis {
    NSMutableString * result = [NSMutableString stringWithString:self.transitGlobalVarJSRepresentation];
    [result appendString:@".nativeFunction(\""];
    [result appendString:proxyId];
    [result appendString:@"\""];
    if(async || noThis) {
        [result appendString:@",{"];
        if(async)
            [result appendString:@"async:true"];
        if(async && noThis)
            [result appendString:@","];
        if(noThis)
            [result appendString:@"noThis:true"];
        [result appendString:@"}"];
    }
    [result appendString:@")"];
    
    return result;
}

-(void)disposeAllNativeProxies {
    for (id proxy in _retainedNativeProxies.allValues) {
        [proxy dispose];
    }
}

-(void)drainJSProxies {
    [self              eval:@"(function(ids){"
            "for(var i=0;i<ids.length;i++)"
            "@.releaseElementWithId(ids[i]);"
            "})(@)" thisArg:nil values:@[_transitGlobalVarJSRepresentation, _jsProxiesToBeReleased] returnJSResult:NO];
    [_jsProxiesToBeReleased removeAllObjects];
    
}


-(void)releaseJSProxyWithId:(NSString*)id {
    [_jsProxiesToBeReleased addObject:id];
    if(_jsProxiesToBeReleased.count > _TRANSIT_DRAIN_JS_PROXIES_THRESHOLD)
        [self drainJSProxies];
}

-(NSString*)nextNativeFunctionId {
    return [NSString stringWithFormat:@"%d", ++_lastNativeFunctionId];
}

-(TransitFunction*)functionWithGenericBlock:(TransitGenericFunctionBlock)block {
    TransitNativeFunction* function = [[TransitNativeFunction alloc] initWithContext:self nativeId:[self nextNativeFunctionId] genericBlock:block];
    [self retainNativeFunction:function];
    return function;
}

-(TransitFunction*)functionWithDelegate:(id<TransitFunctionBodyProtocol>)delegate {
    return [self functionWithGenericBlock:[TransitNativeFunction genericFunctionBlockWithDelegate:delegate]];
}

-(TransitFunction*)functionWithBlock:(id)block {
    return [self functionWithGenericBlock:[TransitNativeFunction genericFunctionBlockWithBlock:block]];
}

-(TransitFunction*)asyncFunctionWithGenericBlock:(TransitGenericVoidFunctionBlock)block {
    TransitNativeFunction* func = (TransitNativeFunction*) [self functionWithGenericBlock:^id(TransitNativeFunctionCallScope *scope) {
        block(scope);
        return nil;
    }];
    func.async = YES;
    return func;
}

-(TransitFunction*)replaceFunctionAt:(NSString *)path withGenericBlock:(TransitGenericReplaceFunctionBlock)block {
    TransitFunction *original = [self eval:path];
    if(!original)
        return nil;
    
    TransitFunction *function = [self functionWithGenericBlock:^id(TransitNativeFunctionCallScope *scope) {
        TransitFunction *oldOriginalFunctionForCurrentCall = _TransitCurrentCall_originalFunctionForCurrentCall;
        @try {
            _TransitCurrentCall_originalFunctionForCurrentCall = original;
            return block(original, scope);
        }@finally{
            _TransitCurrentCall_originalFunctionForCurrentCall = oldOriginalFunctionForCurrentCall;
        }
    }];

    [self eval:@"@ = @" values:@[transit_stringAsJSExpression(path), function]];
    
    return function;
}

-(TransitFunction*)replaceFunctionAt:(NSString *)path withBlock:(id)block {
    TransitGenericFunctionBlock genericBlock = [TransitNativeFunction genericFunctionBlockWithBlock:block];
    TransitGenericReplaceFunctionBlock genericReplaceBlock = ^id(TransitFunction *original, TransitNativeFunctionCallScope *callScope) {
        return genericBlock(callScope);
    };
    return [self replaceFunctionAt:path withGenericBlock:genericReplaceBlock];
}

-(void)retainNativeFunction:(TransitProxy*)proxy {
    NSParameterAssert(proxy.context == self);
    NSParameterAssert(proxy.proxyId);
    
//    if(_retainedNativeProxies[proxy.proxyId])
//        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"cannot retain native proxy twice" userInfo:nil];
    
    _retainedNativeProxies[proxy.proxyId] = proxy;
}

-(void)releaseNativeFunction:(TransitProxy *)proxy {
    NSParameterAssert(proxy.context == self);
    NSParameterAssert(proxy.proxyId);
    
//    id existing = _retainedNativeProxies[proxy.proxyId];
//    if(!existing)
//        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"cannot release unretained proxy" userInfo:nil];

    [_retainedNativeProxies removeObjectForKey:proxy.proxyId];
}

-(NSDictionary*)retainedNativeProxies {
    return _retainedNativeProxies;
}

-(NSString*)transitGlobalVarJSRepresentation {
    return _transitGlobalVarJSRepresentation;
}

-(TransitNativeFunction*)retainedNativeFunctionWithId:(id)nativeProxyId {
    TransitNativeFunction* func = _retainedNativeProxies[nativeProxyId];
    
    if(!func) {
        NSString* reason = [NSString stringWithFormat:@"No native function with id: %@. Could have been disposed.", nativeProxyId];
        @throw [NSException exceptionWithName:@"TransitException" reason:reason userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    
    return func;
}

+(NSRegularExpression*)regularExpressionForMarker:(NSString*)marker {
    static NSMutableDictionary* cache;
    if(!cache)cache = [NSMutableDictionary dictionary];
    
    NSRegularExpression *result = cache[marker];
    if(!result) {
        NSString* pattern = [NSString stringWithFormat:@"^%@([\\d\\w]+)$", [NSRegularExpression escapedPatternForString:marker]];
        result = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        cache[marker] = result;
    }
    return result;
}

+(id)proxyIdFromString:(NSString*)string atGroupIndex:(NSUInteger)idx forMarker:(NSString*)marker {
    NSRegularExpression* expression = [self regularExpressionForMarker:marker];
    NSTextCheckingResult *match = [expression firstMatchInString:string options:0 range:NSMakeRange(0, string.length)];
    if(match) {
        return [string substringWithRange:[match rangeAtIndex:idx]];
    }
    return nil;
}

-(id)recursivelyReplaceMarkersWithProxies:(id)unproxified {
    if([unproxified isKindOfClass:NSString.class]) {
        if([unproxified length] >= _TRANSIT_MARKER_PREFIX_MIN_LEN && [unproxified characterAtIndex:0] == '_' && [unproxified characterAtIndex:1] == '_') {
            id jsFunctionProxyId = [self.class proxyIdFromString:unproxified atGroupIndex:0 forMarker:_TRANSIT_MARKER_PREFIX_JS_FUNCTION_];
            if(jsFunctionProxyId)
                return [[TransitJSFunction alloc] initWithContext:self proxyId:jsFunctionProxyId];
            
            id objectProxyId = [self.class proxyIdFromString:unproxified atGroupIndex:0 forMarker:_TRANSIT_MARKER_PREFIX_OBJECT_PROXY_];
            if(objectProxyId)
                return [[TransitProxy alloc] initWithContext:self proxyId:objectProxyId];
            
            id nativeFunctionProxyId = [self.class proxyIdFromString:unproxified atGroupIndex:1 forMarker:_TRANSIT_MARKER_PREFIX_NATIVE_FUNCTION];
            if(nativeFunctionProxyId)
                return [self retainedNativeFunctionWithId:nativeFunctionProxyId];
            
            if([_TRANSIT_MARKER_GLOBAL_OBJECT isEqualToString:unproxified])
                return self;
        }
    }
    if([unproxified isKindOfClass:NSDictionary.class]) {
        // JSONParser already returns mutable values
        //NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:unproxified];
        NSMutableDictionary *dict = unproxified;
        for (id key in dict.allKeys) {
            dict[key] = [self recursivelyReplaceMarkersWithProxies:dict[key]];
        }
        return dict;
    }
    if([unproxified isKindOfClass:NSArray.class]) {
        // JSONParser already returns mutable values
        //NSMutableArray *array = [NSMutableArray arrayWithArray:unproxified];
        NSMutableArray *array = unproxified;
        for(int i=0; i<array.count; i++)
            array[i] = [self recursivelyReplaceMarkersWithProxies:array[i]];
        return array;
    }

    return unproxified;
}

- (id)recursivelyReplaceBlocksWithNativeFunctions:(id)value {
    if([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dict = [value mutableCopy];
        for (id key in dict.allKeys) {
            dict[key] = [self recursivelyReplaceBlocksWithNativeFunctions:dict[key]];
        }
        return dict;
    }
    if([value isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [value mutableCopy];
        for(NSUInteger i=0; i<array.count; i++)
            array[i] = [self recursivelyReplaceBlocksWithNativeFunctions:array[i]];
        return array;
    }
    if([value isKindOfClass:NSClassFromString(@"NSBlock")]) {
        return [self functionWithBlock:value];
    }

    return value;
}

-(id)invokeNativeWithDescription:(NSDictionary*)description {
    id nativeProxyId = description[@"nativeId"];
    TransitFunction* func;
    @try {
        func = [self retainedNativeFunctionWithId:nativeProxyId];
    } @catch (NSException *exception) {
        NSError* error = transit_errorWithCodeFromException(5, exception);
        NSLog(@"TRANSIT-BRIDGE-ERROR: %@ (while called from JavaScript)", error.userInfo[NSLocalizedDescriptionKey]);
        return error;
    }
    
    id thisArg = description[@"thisArg"];
    NSArray *arguments = description[@"args"];
    @try {
        id result = [func callWithThisArg:thisArg arguments:arguments];
        return result;
    }
    @catch (NSException *exception) {
        NSError* error = transit_errorWithCodeFromException(5, exception);
        NSLog(@"TRANSIT-NATIVE-ERROR: %@ (while called from javascript with arguments %@)", error.userInfo[NSLocalizedDescriptionKey], arguments);
        return error;
    }
    @finally {

    }
}

- (id)invokeNativeFunc:(TransitNativeFunction *)func thisArg:(id)thisArg arguments:(NSArray *)arguments expectsResult:(BOOL)expectsResult {
    if(thisArg == nil || thisArg == NSNull.null) {
        thisArg = self;
    }

    TransitNativeFunctionCallScope *scope = [[TransitNativeFunctionCallScope alloc] initWithContext:self parentScope:_currentCallScope thisArg:thisArg arguments:arguments expectsResult:expectsResult function:func];
    _currentCallScope = scope;
    TransitContext *oldTransitContextCurrentContext = _TransitCurrentCall_currentContext;
    _TransitCurrentCall_currentContext = self;
    @try {
        return [func _callWithScope:scope];
    }
    @finally {
        _TransitCurrentCall_currentContext = oldTransitContextCurrentContext;
        _currentCallScope = _currentCallScope.parentScope;
    }
}

- (id)_eval:(NSString *)jsExpression jsThisArg:(NSString *)jsAdjustedThisArg collectedProxiesOnScope:(NSOrderedSet *)proxiesOnScope returnJSResult:(BOOL)returnJSResult onGlobalScope:(BOOL)globalScope useAndRestoreCallScope:(TransitCallScope *)callScope {
    @throw @"to be implemented by subclass";
}

- (id)_eval:(NSString *)jsCode thisArg:(id)thisArg values:(NSArray *)arguments returnJSResult:(BOOL)returnJSResult useAndRestoreCallScope:(TransitCallScope *)callScope {
    @throw @"to be implemented by subclass";
}

-(void)handleQueuedAsyncCallsToJSFunctions{
    if(_queuedAsyncCallsToJSFunctions.count <= 0)
        return;
    
    NSMutableString* js = [NSMutableString stringWithString:@""];
    NSMutableOrderedSet* proxiesOnScope = NSMutableOrderedSet.orderedSet;
    
    for(TransitQueuedCallToJSFunction* queuedCall in _queuedAsyncCallsToJSFunctions) {
        [js appendString:[queuedCall jsRepresentationOfCallCollectingProxiesOnScope:proxiesOnScope]];
    }
    [_queuedAsyncCallsToJSFunctions removeAllObjects];

    TransitCallScope *callScope = [TransitAsyncCallScope.alloc initWithContext:self parentScope:_currentCallScope thisArg:nil expectsResult:NO];
    [self _eval:js jsThisArg:@"null" collectedProxiesOnScope:proxiesOnScope returnJSResult:NO onGlobalScope:NO useAndRestoreCallScope:callScope];
}

-(void)queueAsyncCallToJSFunction:(TransitJSFunction*)jsFunc thisArg:(id)thisArg arguments:(NSArray*)arguments {
    [_queuedAsyncCallsToJSFunctions addObject:[TransitQueuedCallToJSFunction.alloc initWithJSFunction:jsFunc thisArg:thisArg arguments:arguments]];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleQueuedAsyncCallsToJSFunctions) object:nil];
    [self performSelector:@selector(handleQueuedAsyncCallsToJSFunctions) withObject:nil afterDelay:_TRANSIT_ASYNC_CALL_DELAY];
}

- (void)pushCallScope:(TransitCallScope *)scope {
    NSParameterAssert(scope.parentScope == _currentCallScope);
    _currentCallScope = scope;
}

- (void)popCallScope {
    NSAssert(_currentCallScope != nil, @"cannot pop call scope any further");
    _currentCallScope = _currentCallScope.parentScope;
}

- (BOOL)evalContentsOfFileOnGlobalScope:(NSString *)path encoding:(NSStringEncoding)encoding error:(NSError **)error {
    NSString* jsCode = [NSString stringWithContentsOfFile:path encoding:encoding error:error];
    if(jsCode)
        [self evalOnGlobalScope:jsCode];
    return jsCode != nil;
}

- (void)evalOnGlobalScope:(NSString *)jsCode {
    TransitCallScope *callScope = [TransitEvalCallScope.alloc initWithContext:self parentScope:_currentCallScope thisArg:self jsCode:jsCode values:@[] expectsResult:NO];
    [self _eval:jsCode jsThisArg:@"null" collectedProxiesOnScope:nil returnJSResult:NO onGlobalScope:YES useAndRestoreCallScope:callScope];
}
@end

@implementation TransitQueuedCallToJSFunction {
    TransitJSFunction* _jsFunc;
    id _thisArg;
    NSArray* _arguments;
    NSString*__collectedJS;
    NSOrderedSet*__collectedProxiesOnScope;
}

-(id)initWithJSFunction:(TransitJSFunction*)jsFunc thisArg:(id)thisArg arguments:(NSArray*)arguments {
    self = [self init];
    if(self) {
        _jsFunc = jsFunc;
        _thisArg = thisArg;
        _arguments = arguments;
    }
    return self;
}

-(NSString*)jsRepresentationOfCallCollectingProxiesOnScope:(NSMutableOrderedSet*)proxiesOnScope {
    [_jsFunc onEvaluator:self callWithThisArg:_thisArg arguments:_arguments returnResult:NO buildCallScope:NO];
    [proxiesOnScope addObjectsFromArray:__collectedProxiesOnScope.array];
    return __collectedJS;
}

- (id)_eval:(NSString *)jsExpression jsThisArg:(NSString *)jsAdjustedThisArg collectedProxiesOnScope:(NSOrderedSet *)proxiesOnScope returnJSResult:(BOOL)returnJSResult onGlobalScope:(BOOL)globalScope useAndRestoreCallScope:(TransitCallScope *)callScope {
    __collectedProxiesOnScope = proxiesOnScope;

    if([@"null" isEqualToString:jsAdjustedThisArg]) {
        __collectedJS = [NSString stringWithFormat:@"%@;", jsExpression];
    } else {
        __collectedJS = [NSString stringWithFormat:@"(function(){%@}).apply(%@);", jsExpression, jsAdjustedThisArg];
    }
    return nil;
}

- (id)_eval:(NSString *)jsCode thisArg:(id)thisArg values:(NSArray *)arguments returnJSResult:(BOOL)returnJSResult useAndRestoreCallScope:(TransitCallScope *)callScope {
    NSMutableOrderedSet *proxiesOnScope = NSMutableOrderedSet.orderedSet;

    NSString* jsExpression = [TransitProxy jsRepresentationFromCode:jsCode arguments:arguments collectingProxiesOnScope:proxiesOnScope];
    id adjustedThisArg = thisArg == _jsFunc.context ? nil : thisArg;
    NSString* jsAdjustedThisArg = adjustedThisArg ? [TransitProxy jsRepresentation:thisArg collectingProxiesOnScope:proxiesOnScope] : @"null";

    return [self _eval:jsExpression jsThisArg:jsAdjustedThisArg collectedProxiesOnScope:proxiesOnScope returnJSResult:returnJSResult onGlobalScope:NO useAndRestoreCallScope:callScope];
}


@end

@implementation TransitFunction

-(id)call {
    return [self callWithThisArg:nil arguments:@[] returnResult:YES];
}

-(id)callWithArg:(id)arg0 {
    return [self callWithThisArg:nil arguments:@[TransitNilSafe(arg0)] returnResult:YES];
}
            
-(id)callWithArg:(id)arg0 arg:(id)arg1 {
    return [self callWithThisArg:nil arguments:@[TransitNilSafe(arg0), TransitNilSafe(arg1)] returnResult:YES];
}

-(id)callWithArg:(id)arg0 arg:(id)arg1 arg:(id)arg2 {
    return [self callWithThisArg:nil arguments:@[TransitNilSafe(arg0), TransitNilSafe(arg1), TransitNilSafe(arg2)] returnResult:YES];
}

-(id)callWithArguments:(NSArray*)arguments {
    return [self callWithThisArg:nil arguments:arguments returnResult:YES];
}

-(id)callWithThisArg:(id)thisArg {
    return [self callWithThisArg:thisArg arguments:@[] returnResult:YES];
}

-(id)callWithThisArg:(id)thisArg arg:(id)arg0 {
    return [self callWithThisArg:thisArg arguments:@[TransitNilSafe(arg0)] returnResult:YES];
}

-(id)callWithThisArg:(id)thisArg arg:(id)arg0 arg:(id)arg1 {
    return [self callWithThisArg:thisArg arguments:@[TransitNilSafe(arg0), TransitNilSafe(arg1)] returnResult:YES];
}

-(id)callWithThisArg:(id)thisArg arguments:(NSArray*)arguments {
    return [self callWithThisArg:thisArg arguments:arguments returnResult:YES];
}

-(id)callWithThisArg:(id)thisArg arguments:(NSArray *)arguments returnResult:(BOOL)returnResult {
    @throw [NSException exceptionWithName:@"Abstract" reason:@"must be implemented by subclass" userInfo:nil];;
}

-(void)callAsync {
    [self callAsyncWithThisArg:nil arguments:@[]];
}

-(void)callAsyncWithArg:(id)arg0 {
    [self callAsyncWithThisArg:nil arguments:@[TransitNilSafe(arg0)]];
}

-(void)callAsyncWithArg:(id)arg0 arg:(id)arg1 {
    [self callAsyncWithThisArg:nil arguments:@[TransitNilSafe(arg0), TransitNilSafe(arg1)]];
}

-(void)callAsyncWithArguments:(NSArray*)arguments {
    [self callAsyncWithThisArg:nil arguments:arguments];
}

-(void)callAsyncWithThisArg:(id)thisArg arguments:(NSArray*)arguments {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self callWithThisArg:thisArg arguments:arguments returnResult:NO];
    });
}


@end

@implementation TransitNativeFunction

-(id)initWithContext:(TransitContext *)context nativeId:(NSString *)nativeId genericBlock:(TransitGenericFunctionBlock)block {
    self = [self initWithContext:context proxyId:nativeId];
    if(self) {
        NSParameterAssert(nativeId);
        NSParameterAssert(block);
        _block = [block copy];
    }
    return self;
}

+ (TransitGenericFunctionBlock)genericFunctionBlockWithDelegate:(id <TransitFunctionBodyProtocol>)delegate {
    return ^id(TransitNativeFunctionCallScope *scope) {
        return [delegate callWithFunction:scope.function thisArg:scope.thisArg arguments:scope.arguments expectsResult:scope.expectsResult];
    };
}

+ (void)assertSpecificBlockCanBeUsedAsTransitFunction:(id)block {
    if(![block isKindOfClass:NSClassFromString(@"NSBlock")])
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"expected block but was %@", NSStringFromClass([block class])] userInfo:nil];

    TransitCTBlockDescription *desc = [TransitCTBlockDescription.alloc initWithBlock:block];
    NSMethodSignature *sig = desc.blockSignature;

    void(^assertValidType)(char const*, NSString*) = ^(char const* typeChar, NSString* suffix){
        if(strchr("cislqCISLQfdBv@", typeChar[0]) == NULL)
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"unsupported type %c for %@", typeChar[0], suffix] userInfo:nil];
    };

    assertValidType(sig.methodReturnType, @"return type");
    for(NSUInteger i=0;i<sig.numberOfArguments;i++)
        assertValidType([sig getArgumentTypeAtIndex:i], [NSString stringWithFormat:@"argument at index %ld", (unsigned long)i]);
}

+ (TransitGenericFunctionBlock)genericFunctionBlockWithBlock:(id)block {
    // additional runtime-check, in case TRANSIT_SPECIFIC_BLOCKS_SUPPORTED has been overriden (e.g. for unit tests)
    if(!transit_specificBlocksSupported())
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"specific blocks are not supported on this version/platform" userInfo:nil];

    [self assertSpecificBlockCanBeUsedAsTransitFunction:block];
    return ^id(TransitNativeFunctionCallScope *callScope) {
        TransitCTBlockDescription *desc = [TransitCTBlockDescription.alloc initWithBlock:block];
        NSMethodSignature *sig = desc.blockSignature;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];

        // arg 0 of invocation is self and will be block
        for(NSUInteger i=0;i<MIN(sig.numberOfArguments-1, callScope.arguments.count);i++)
            [inv transit_setObject:callScope.arguments[i] forArgumentAtIndex:i + 1];

//        // this would work on iOS5 but is private API
//        // should there be another pre compiler flag to allow them?
//        inv.target = block;
//        void* impl = ((__bridge struct TransitCTBlockLiteral *)block)->invoke;
//        [inv invokeUsingIMP:impl];

        // does not work on iOS 5
        [inv invokeWithTarget:block];
        return inv.transit_returnValueAsObject;
    };
}


-(id)_callWithScope:(TransitNativeFunctionCallScope *)scope {
    return _block(scope);
}

-(id)callWithThisArg:(id)thisArg arguments:(NSArray*)arguments returnResult:(BOOL)returnResult {
    id result = [self.context invokeNativeFunc:self thisArg:thisArg arguments:arguments expectsResult:returnResult];
    return returnResult ? result : nil;
}

-(NSString*)_jsRepresentationCollectingProxiesOnScope:(NSMutableOrderedSet*)proxiesOnScope {
    [proxiesOnScope addObject:self];
    return [self.context jsRepresentationForNativeFunctionWithId:self.proxyId];
}

-(NSString*)jsRepresentationToResolveProxy {
    return [self.context jsRepresentationToResolveNativeFunctionWithId:self.proxyId async:self.async noThis:self.noThis];
}

-(void)dispose {
    if(self.context) {
        if(self.proxyId)
            [self.context releaseNativeFunction:self];
        [self clearContextAndProxyId];
    }
}

@end


@implementation TransitJSFunction

- (id)onEvaluator:(id <TransitEvaluator>)evaluator callWithThisArg:(id)thisArg arguments:(NSArray *)arguments returnResult:(BOOL)returnResult buildCallScope:(BOOL)buildCallScope {
    if(self.disposed)
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"function already disposed" userInfo:nil];
    
    BOOL noSpecificThisArg = (thisArg == nil) || (thisArg == self.context);

    TransitCallScope *callScope;
    if(buildCallScope) {
        callScope = [TransitJSFunctionCallScope.alloc initWithContext:self.context parentScope:self.context.currentCallScope thisArg:thisArg arguments:arguments expectsResult:returnResult function:self];
    }

    if(noSpecificThisArg) {
        // most frequent cases: zore or one argument, no specific this arg
        NSMutableOrderedSet *proxiesOnScope = [NSMutableOrderedSet orderedSet];
        NSString* jsFunc = [self _jsRepresentationCollectingProxiesOnScope:proxiesOnScope];
        NSMutableArray* jsArgs = [NSMutableArray arrayWithCapacity:arguments.count];
        for(id arg in arguments) {
            [jsArgs addObject:[TransitProxy jsRepresentation:arg collectingProxiesOnScope:proxiesOnScope]];
        }
        NSString* jsCall = [NSString stringWithFormat:@"%@(%@)", jsFunc, [jsArgs componentsJoinedByString:@","]];

        return [evaluator _eval:jsCall jsThisArg:@"null" collectedProxiesOnScope:proxiesOnScope returnJSResult:returnResult onGlobalScope:NO useAndRestoreCallScope:callScope];
    } else {
        // general case
        return [evaluator _eval:@"@.apply(@,@)" thisArg:nil values:@[self, TransitNilSafe(thisArg), (arguments ? arguments : @[])] returnJSResult:returnResult useAndRestoreCallScope:callScope];
    }
}

-(id)callWithThisArg:(id)thisArg arguments:(NSArray *)arguments returnResult:(BOOL)returnResult {
    return [self onEvaluator:self.context callWithThisArg:thisArg arguments:arguments returnResult:returnResult buildCallScope:YES];
}

// remove this method if you do not want to call async JS functions in bulk
-(void)callAsyncWithThisArg:(id)thisArg arguments:(NSArray*)arguments {
    [self.context queueAsyncCallToJSFunction:self thisArg:thisArg arguments:arguments];
}

@end

@implementation TransitCallScope

- (id)initWithContext:(TransitContext *)context parentScope:(TransitCallScope *)parentScope thisArg:(id)thisArg expectsResult:(BOOL)expectsResult {
    self = [self initWithContext:context];
    if(self) {
        _parentScope = parentScope;
        _thisArg = thisArg ? thisArg : context;
        _expectsResult = expectsResult;
    }
    return self;
}

-(NSUInteger)level {
    return self.parentScope.level + 1;
}

- (NSString*)description {
    return [NSString stringWithFormat:@"%.3ld %@(this=%@)", (unsigned long)self.level, NSStringFromClass(self.class), self.thisArg];
}

- (NSString *)callStackDescription {
    NSMutableArray *stackSymbols = NSMutableArray.new;
    TransitCallScope *scope = self;
    while(scope) {
        [stackSymbols addObject:scope.callStackFrameDescription];
        scope = scope.parentScope;
    }

    return [stackSymbols componentsJoinedByString:@"\n"];
}

- (NSString *)callStackFrameDescription {
    return [NSString stringWithFormat:@"unkown call frame %@", NSStringFromClass(self.class)];
}

@end

@implementation TransitEvalCallScope : TransitCallScope

- (id)initWithContext:(TransitContext *)parentScope parentScope:(TransitCallScope *)scope thisArg:(id)thisArg jsCode:(NSString *)jsCode values:(NSArray *)values expectsResult:(BOOL)expectsResult {
    self = [self initWithContext:parentScope parentScope:scope thisArg:thisArg expectsResult:expectsResult];
    if(self) {
        _jsCode = [jsCode copy];
        _values = [values copy];
    }
    return self;
}

- (NSString *)callStackFrameDescription {
    return [NSString stringWithFormat:@"%@ %@ -- values:(%@)", self.description, self.jsCode, [self.values componentsJoinedByString:@", "]];
}

@end

@implementation TransitFunctionCallScope : TransitCallScope

- (id)initWithContext:(TransitContext *)context parentScope:(TransitCallScope *)parentScope thisArg:(id)arg arguments:(NSArray *)arguments expectsResult:(BOOL)expectsResult function:(TransitFunction *)function {
    self = [self initWithContext:context parentScope:parentScope thisArg:arg expectsResult:expectsResult];
    if(self) {
        _function = function;
        _arguments = [arguments copy];
    }
    return self;
}

- (id)objectForImplicitVars {
    return self.thisArg;
}

- (id)forwardToFunction:(TransitFunction *)function {
    return [function callWithThisArg:self.thisArg arguments:self.arguments returnResult:self.expectsResult];
}

-(id)forwardToDelegate:(id<TransitFunctionBodyProtocol>)delegate {
    return [delegate callWithFunction:self.function thisArg:self.thisArg arguments:self.arguments expectsResult:self.expectsResult];
}

- (NSString *)callStackFrameDescription {
    return [NSString stringWithFormat:@"%@(%@)", self.description, [self.arguments componentsJoinedByString:@", "]];
}

@end

@implementation TransitAsyncCallScope : TransitCallScope
@end

@implementation TransitJSFunctionCallScope : TransitFunctionCallScope
@end

@implementation TransitNativeFunctionCallScope : TransitFunctionCallScope
@end

@implementation NSInvocation (TransitAdditions)

-(void)transit_setObject:(id)object forArgumentAtIndex:(NSUInteger)index {
    const char* argType = [self.methodSignature getArgumentTypeAtIndex:index];
    switch(argType[0]) {
        //cislqCISLQfdBv@
        case 'c': {
            char value = [object charValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'i': {
            int value = [object intValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 's': {
            short value = [object shortValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'l': {
            long value = [object longValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'q': {
            long long value = [object longLongValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'C': {
            unsigned char value = [object unsignedCharValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'I': {
            unsigned int value = [object unsignedIntValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'S': {
            unsigned short value = [object unsignedShortValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'L': {
            unsigned long value = [object unsignedLongValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'Q': {
            unsigned long long value = [object unsignedLongLongValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'f': {
            float value = [object floatValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'd': {
            double value = [object doubleValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case 'B': {
            BOOL value = [object boolValue];
            [self setArgument:&value atIndex:index];
            return;
        }
        case '@': {
            id value = object;
            [self setArgument:&value atIndex:index];
            return;
        }
        default:
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"unsupported type %c for argument at index %ld", argType[0], (unsigned long)index] userInfo:nil];
    }
}

-(id)transit_returnValueAsObject {
    if(self.methodSignature.methodReturnLength<=0)
        return nil;

    const char* argType = [self.methodSignature methodReturnType];
    switch(argType[0]) {
        //cislqCISLQfdBv@
        case 'c': {
            char value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'i': {
            int value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 's': {
            short value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'l': {
            long value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'q': {
            long long value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'C': {
            unsigned char value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'I': {
            unsigned int value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'S': {
            unsigned short value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'L': {
            unsigned long value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'Q': {
            unsigned long long value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'f': {
            float value;
            [self getReturnValue:&value];
            return @(value);
        }
        case 'd': {
            double value;
            [self getReturnValue:&value];
            return @(value);
        }
        case '@': {
            __unsafe_unretained id value;
            [self getReturnValue:&value];
            return value;
        }
        default:
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"unsupported type %c for returm type", argType[0]] userInfo:nil];
    }
}

@end

TransitWebViewContextRequestHandler _TRANSIT_DEFAULT_UIWEBVIEW_REQUEST_HANDLER = ^(TransitAbstractWebViewContext* ctx,NSURLRequest* request) {
    [ctx doInvokeNative];
};

@implementation TransitAbstractWebViewContext {
    SBJsonParser *_parser;
    BOOL _codeInjected;
    BOOL _proxifyEval;
    TransitWebViewContextRequestHandler _handleRequestBlock;
    NSString* _lastEvaluatedJSCode;
}

- (id)init {
    self = [super init];
    if(self) {
        _proxifyEval = YES;
        _parser = SBJsonParser.new;
        _handleRequestBlock = _TRANSIT_DEFAULT_UIWEBVIEW_REQUEST_HANDLER;
    }
    return self;
}

-(BOOL)codeInjected {
    return _codeInjected;
}

-(NSString*)_eval:(NSString*)js returnJSONResult:(BOOL)returnJSONResult{
    if(returnJSONResult) {
        _lastEvaluatedJSCode = [NSString stringWithFormat: @"JSON.stringify(%@)", js];
        return [self _stringByEvaluatingJavaScriptFromString: _lastEvaluatedJSCode];
    } else {
        //        NSLog(@"eval: %@", js);
        return [self _stringByEvaluatingJavaScriptFromString:js];
    }
}

- (NSString *)_stringByEvaluatingJavaScriptFromString:(NSString *)js {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

-(void)updateCodeInjected {
    _codeInjected = [[self _eval:@"typeof transit" returnJSONResult:NO] isEqualToString:@"object"];
}

-(void)injectCodeToWebView {
    [self updateCodeInjected];
    if(!_codeInjected) {
        [self eval:_TRANSIT_JS_RUNTIME_CODE];
        _codeInjected = YES;
    }
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(change[NSKeyValueChangeNewKey] != self && [@[@"delegate", @"frameLoadDelegate"] containsObject:keyPath])
        @throw [NSException exceptionWithName:@"TransitException" reason:@"WebView's delegate must not be changed" userInfo:@{NSLocalizedDescriptionKey: @"WebView's delegate must not be changed"}];

    // not implemented in super class
    // [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

-(BOOL)proxifyEval {
    return _proxifyEval;
}

-(void)setProxifyEval:(BOOL)proxifyEval {
    _proxifyEval = proxifyEval;
}


-(id)parseJSON:(NSString*)json {
    return [_parser objectWithString:json];
}

-(void)doInvokeNative {
    // nativeInvokeTransferObject is safe to parse and contains proxy-ids
    NSString* jsReadTransferObject = [NSString stringWithFormat:@"JSON.stringify(%@.nativeInvokeTransferObject)",self.transitGlobalVarJSRepresentation];

    NSString* jsonDescription = [self _eval:jsReadTransferObject returnJSONResult:NO];
    id parsedJSON = [self parseJSON:jsonDescription];

    // try to replace markers (could fail due to disposed native proxies)
    id transferObject;
    id result;
    @try {
        transferObject = [self recursivelyReplaceMarkersWithProxies:parsedJSON];
    }
    @catch (NSException *exception) {
        result = transit_errorWithCodeFromException(3, exception);
        NSLog(@"TRANSIT-BRIDGE-ERROR: %@ (while called from JavaScript)", [result userInfo][NSLocalizedDescriptionKey]);
    }

    BOOL expectsResult = YES;

    // if was an error while replacing markers (e.g. due to disposed native function) result is filled with an NSError by now
    if(!result) {
        // transferObject is an array => this is a queue of callDescriptions
        // perform each call and ignore results
        if([transferObject isKindOfClass:NSArray.class]) {
            NSLog(@"invoke async functions in bulk of %d elements", [transferObject count]);
            for(NSDictionary* singleCallDescription in transferObject) {
                [self invokeNativeWithDescription:singleCallDescription];
            }
            expectsResult = NO;
        } else {
            // transferObject is a single callDescription
            // will return NSError if an exception occured
            result = [self invokeNativeWithDescription:transferObject];
        }
    }

    if(expectsResult) {
        NSMutableOrderedSet *proxiesOnScope = NSMutableOrderedSet.orderedSet;
        NSString* jsResult = [TransitProxy jsRepresentation:result collectingProxiesOnScope:proxiesOnScope];
        NSString* js = [NSString stringWithFormat:@"%@.nativeInvokeTransferObject=%@", self.transitGlobalVarJSRepresentation, jsResult];
        [self _eval:js jsThisArg:@"null" collectedProxiesOnScope:proxiesOnScope returnJSResult:NO onGlobalScope:NO useAndRestoreCallScope:nil];
    }
}

-(void)setHandleRequestBlock:(TransitWebViewContextRequestHandler)testCallBlock {
    _handleRequestBlock = [testCallBlock copy];
}

-(TransitWebViewContextRequestHandler)handleRequestBlock {
    return _handleRequestBlock;
}

-(NSString *)lastEvaluatedJSCode {
    return _lastEvaluatedJSCode;
}

- (id)_eval:(NSString *)jsExpression jsThisArg:(NSString *)jsAdjustedThisArg collectedProxiesOnScope:(NSOrderedSet *)proxiesOnScope returnJSResult:(BOOL)returnJSResult onGlobalScope:(BOOL)globalScope useAndRestoreCallScope:(TransitCallScope *)callScope {
    @try {
        if(callScope) {
            [self pushCallScope:callScope];
        }

        NSString* jsApplyExpression;
        NSString* jsWrappedApplyExpression;

        if(globalScope) {
            NSParameterAssert([jsAdjustedThisArg isEqualToString:@"null"]);
            NSParameterAssert(proxiesOnScope.count == 0);
            NSParameterAssert(returnJSResult == NO);
            jsWrappedApplyExpression = jsExpression;
        } else {
            NSMutableString* jsProxiesOnScope = [NSMutableString stringWithString:@""];
            if(proxiesOnScope.count>0) {
                for(TransitProxy* p in proxiesOnScope) {
                    [jsProxiesOnScope appendFormat:@"var %@=%@;", [p _jsRepresentationCollectingProxiesOnScope:nil], p.jsRepresentationToResolveProxy];
                }
            }

            jsApplyExpression = [@"null" isEqualToString:jsAdjustedThisArg] ? jsExpression : [NSString stringWithFormat:@"function(){return %@;}.call(%@)", jsExpression, jsAdjustedThisArg];

            if(!returnJSResult) {
                jsWrappedApplyExpression = [NSString stringWithFormat:@"(function(){"
                                            "%@"
                                            "%@"
                                            "})()", jsProxiesOnScope, jsApplyExpression];
            } else {
                if(self.proxifyEval && self.codeInjected) {
                    jsWrappedApplyExpression = [NSString stringWithFormat:@"(function(){"
                                                "var result;"
                                                "try{"
                                                "%@"
                                                "result = %@;"
                                                "}catch(e){"
                                                "return {e:e.message};"
                                                "}"
                                                "return {v:%@.proxify(result)};"
                                                "})()", jsProxiesOnScope, jsApplyExpression, self.transitGlobalVarJSRepresentation];
                } else {
                    jsWrappedApplyExpression = [NSString stringWithFormat:@"(function(){"
                                                "try{"
                                                "%@"
                                                "return {v:%@};"
                                                "}catch(e){"
                                                "return {e:e.message};"
                                                "}"
                                                "})()", jsProxiesOnScope, jsApplyExpression];
                }
            }
        }

        NSString* jsonResult = [self _eval:jsWrappedApplyExpression returnJSONResult:returnJSResult];

        if(!returnJSResult)
            return nil;

        id parsedObject = [self parseJSON:jsonResult];
        if(parsedObject == nil) {
            NSException *e = [NSException exceptionWithName:@"TransitException"
                                                     reason:[NSString stringWithFormat:@"Invalid JavaScript: %@", jsApplyExpression] userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Error while evaluating JavaScript. Seems to be invalid: %@", jsApplyExpression]}];

            NSLog(@"TRANSIT-JS-ERROR: %@ while evaluating %@", e, jsApplyExpression);
            @throw e;
        }

        if(parsedObject[@"e"]) {
            NSException *e = [NSException exceptionWithName:@"TransitException" reason:parsedObject[@"e"] userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Error while executing JavaScript: %@", parsedObject[@"e"]]}];
            NSLog(@"TRANSIT-JS-ERROR: %@ while evaluating %@", e, jsApplyExpression);
            @throw e;
        }
        id parsedResult = parsedObject[@"v"];
        id enhancedResult = parsedResult;
        if(self.proxifyEval)
            enhancedResult = [self recursivelyReplaceMarkersWithProxies:parsedResult];

        return enhancedResult;
    }
    @finally {
        if(callScope) {
            [self popCallScope];
        }
    }
}

- (id)_eval:(NSString *)jsCode thisArg:(id)thisArg values:(NSArray *)values returnJSResult:(BOOL)returnJSResult useAndRestoreCallScope:(TransitCallScope *)callScope {
    NSMutableOrderedSet *proxiesOnScope = NSMutableOrderedSet.orderedSet;

    values = [self recursivelyReplaceBlocksWithNativeFunctions:values];
    NSString* jsExpression = [TransitProxy jsRepresentationFromCode:jsCode arguments:values collectingProxiesOnScope:proxiesOnScope];
    id adjustedThisArg = thisArg == self ? nil : thisArg;
    NSString* jsAdjustedThisArg = adjustedThisArg ? [TransitProxy jsRepresentation:thisArg collectingProxiesOnScope:proxiesOnScope] : @"null";

    return [self _eval:jsExpression jsThisArg:jsAdjustedThisArg collectedProxiesOnScope:proxiesOnScope returnJSResult:returnJSResult onGlobalScope:NO useAndRestoreCallScope:callScope];
}

-(id)eval:(NSString *)jsCode thisArg:(id)thisArg values:(NSArray *)values returnJSResult:(BOOL)returnJSResult {
    TransitCallScope *callScope = [TransitEvalCallScope.alloc initWithContext:self parentScope:self.currentCallScope thisArg:thisArg jsCode:jsCode values:values expectsResult:returnJSResult];
    return [self _eval:jsCode thisArg:thisArg values:values returnJSResult:returnJSResult useAndRestoreCallScope:callScope];
}
@end

NSString* _TRANSIT_SCHEME = @"transit";


#pragma mark - iOS-specific code

#if TRANSIT_OS_IOS

@implementation TransitUIWebViewContext{
    id<UIWebViewDelegate> _originalDelegate;
}

+(id)contextWithUIWebView:(UIWebView*)webView {
    return [[self alloc] initWithUIWebView: webView];
}

-(id)initWithUIWebView:(UIWebView*)webView {
    self = [self init];
    if(self) {
        _webView = webView;
        [self bindToWebView];
    }
    return self;
}

-(void)dealloc {
    [_webView removeObserver:self forKeyPath:@"delegate"];
}

-(void)bindToWebView {
    _originalDelegate = _webView.delegate;
    _webView.delegate = self;
    [_webView addObserver:self forKeyPath:@"delegate" options:NSKeyValueObservingOptionNew context:nil];
    [self injectCodeToWebView];
}

- (NSString *)_stringByEvaluatingJavaScriptFromString:(NSString *)js {
    return [_webView stringByEvaluatingJavaScriptFromString:js];
}

#pragma UIWebViewDelegate

-(BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {
    if([request.URL.scheme isEqual:_TRANSIT_SCHEME]){
        if(self.handleRequestBlock)
            self.handleRequestBlock(self, request);
        
        return NO;
    }
    
    if([_originalDelegate respondsToSelector:_cmd])
        return [_originalDelegate webView:webView shouldStartLoadWithRequest:request navigationType:navigationType];
    
    return YES;
}

-(void)webViewDidStartLoad:(UIWebView *)webView {
    if([_originalDelegate respondsToSelector:_cmd])
        return [_originalDelegate webViewDidStartLoad:webView];
}

-(void)webViewDidFinishLoad:(UIWebView *)webView {
    [self injectCodeToWebView];
    
    if([_originalDelegate respondsToSelector:_cmd])
        return [_originalDelegate webViewDidFinishLoad:webView];
    if(self.readyHandler)
        self.readyHandler(self);
}

-(void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    if([_originalDelegate respondsToSelector:_cmd])
        return [_originalDelegate webView:webView didFailLoadWithError:error];
}

@end

#endif

#pragma mark - OSX-specific code

#if TRANSIT_OS_MAC

@implementation TransitWebViewContext {
    __weak id _originalFrameLoadDelegate;
    BOOL _shouldWaitForTransitLoaded;
}

+(id)contextWithWebView:(WebView*)webView {
    return [self.class.new initWithWebView:webView];
}

-(id)initWithWebView:(WebView*)webView {
    self = [self init];
    if(self) {
        _webView = webView;
        [self bindToWebView];
    }
    return self;
}

-(void)dealloc {
    [_webView removeObserver:self forKeyPath:@"frameLoadDelegate"];
}

-(id)originalFrameLoadDelegate {
    return _originalFrameLoadDelegate;
}

-(void)bindToWebView {
    _originalFrameLoadDelegate = _webView.frameLoadDelegate;
    _webView.frameLoadDelegate = self;
    [_webView addObserver:self forKeyPath:@"frameLoadDelegate" options:NSKeyValueObservingOptionNew context:nil];
    [self injectCodeToWebView];
}

- (NSString *)_stringByEvaluatingJavaScriptFromString:(NSString *)js {
    return [_webView stringByEvaluatingJavaScriptFromString:js];
}

#pragma mark - WebFrameLoadDelegate

-(BOOL)shouldWaitForTransitLoaded {
    return _shouldWaitForTransitLoaded;
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {
    if(frame == sender.mainFrame) {

        // avoid race condition: under OSX ML, frame itself is loaded but not every JS
        // so poll for its existence and value of window.transit_loaded == true
        if(self.shouldWaitForTransitLoaded)
            [self pollForTransitLoadedAndEventuallyCallReadyHandler];
        else {
            if(self.readyHandler)
                self.readyHandler(self);
        }
    }

    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:sender didFinishLoadForFrame:frame];
}

- (void)pollForTransitLoadedAndEventuallyCallReadyHandler {
    if(!self.readyHandler)
        return;

//    DDLogVerbose(@"polling for transit loaded: %@", [self _stringByEvaluatingJavaScriptFromString:@"location.href"]);

    NSString* js = @"typeof(transit_loaded)=='boolean' && transit_loaded";
    NSString* result = [self _stringByEvaluatingJavaScriptFromString:js];
    if(result.boolValue) {
//        DDLogVerbose(@"loaded :) calling completionBlock");
        self.readyHandler(self);
    } else {
        // actual polling
        [self performSelector:_cmd withObject:nil afterDelay:0.1];
    }
}

#pragma mark - WebScripting protocol

- (id)invokeUndefinedMethodFromWebScript:(NSString *)name withArguments:(NSArray *)args {
    NSAssert("calling undefined method %@", name);
    return nil;
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)sel
{
    if(sel == @selector(callHandleRequestBlock))
        return NO;
    return YES;
}

+(BOOL)isKeyExcludedFromWebScript:(const char *)name {
    return YES;
}

-(void)callHandleRequestBlock {
    if(self.handleRequestBlock)
        self.handleRequestBlock(self, nil);
}

NSString* TransitWebScriptNamespace = @"transit_callback";

- (void)webView:(WebView *)sender didClearWindowObject:(WebScriptObject *)windowObject forFrame:(WebFrame *)frame {
    if(frame == sender.mainFrame){
        [windowObject setValue:self forKey:TransitWebScriptNamespace];
        [self injectCodeToWebView];
    }
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:sender didClearWindowObject:windowObject forFrame:frame];
}

-(void)injectCodeToWebView {
    [super injectCodeToWebView];
    // temporary workaround, modify grunt.js to build proper string literal
    NSString* customJS = @"(function(){"
        "transit.doInvokeNative = function(invocationDescription){\n"
            "transit.nativeInvokeTransferObject = invocationDescription;\n"
            "transit_callback.callHandleRequestBlock();\n"
            "if(transit.nativeInvokeTransferObject === invocationDescription) {\n"
            "    throw new Error(\"internal error with transit: invocation transfer object not filled.\");\n"
            "}\n"
            "var result = transit.nativeInvokeTransferObject;\n"
            "if(result instanceof Error) {\n"
            "    throw result;\n"
            "} else {\n"
            "    return result;\n"
            "}\n"
        "};"

        "transit.doHandleInvocationQueue = function(invocationDescriptions) {\n"
            "transit.nativeInvokeTransferObject = invocationDescriptions;\n"
            "transit_callback.callHandleRequestBlock();\n"
            "transit.nativeInvokeTransferObject = null;\n"
        "};"

    "})()";



    [self _stringByEvaluatingJavaScriptFromString:customJS];
}
#pragma mark WebFrameLoadDelegate

- (void)webView:(WebView *)webView didStartProvisionalLoadForFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didStartProvisionalLoadForFrame:frame];
};

- (void)webView:(WebView *)webView didReceiveServerRedirectForProvisionalLoadForFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didReceiveServerRedirectForProvisionalLoadForFrame:frame];
};

- (void)webView:(WebView *)webView didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didFailProvisionalLoadWithError:error forFrame:frame];
};

- (void)webView:(WebView *)webView didCommitLoadForFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didCommitLoadForFrame:frame];
};

- (void)webView:(WebView *)webView didReceiveTitle:(NSString *)title forFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didReceiveTitle:title forFrame:frame];
};

- (void)webView:(WebView *)webView didReceiveIcon:(NSImage *)image forFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didReceiveIcon:image forFrame:frame];
};

//- (void)webView:(WebView *)webView didFinishLoadForFrame:(WebFrame *)frame{};

- (void)webView:(WebView *)webView didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didFailLoadWithError:error forFrame:frame];
};

- (void)webView:(WebView *)webView didChangeLocationWithinPageForFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didChangeLocationWithinPageForFrame:frame];
};

- (void)webView:(WebView *)webView willPerformClientRedirectToURL:(NSURL *)URL delay:(NSTimeInterval)seconds fireDate:(NSDate *)date forFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView willPerformClientRedirectToURL:URL delay:seconds fireDate:date forFrame:frame];
};

- (void)webView:(WebView *)webView didCancelClientRedirectForFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView didCancelClientRedirectForFrame:frame];
};

- (void)webView:(WebView *)webView willCloseFrame:(WebFrame *)frame{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView willCloseFrame:frame];
};

//- (void)webView:(WebView *)webView didClearWindowObject:(WebScriptObject *)windowObject forFrame:(WebFrame *)frame{};

- (void)webView:(WebView *)webView windowScriptObjectAvailable:(WebScriptObject *)windowScriptObject{
    if([_originalFrameLoadDelegate respondsToSelector:_cmd])
        [_originalFrameLoadDelegate webView:webView windowScriptObjectAvailable:windowScriptObject];
};



@end

#endif

#pragma mark - Generated Code


// NOTE: this value is automatically generated by grunt. DO NOT CHANGE ANYTHING BEHIND THIS LINE
NSString* _TRANSIT_JS_RUNTIME_CODE = @
    // _TRANSIT_JS_RUNTIME_CODE_START
    "(function(){/*global Document Element */\n\n(function(globalName){\n    var transit = {\n        retained:{},\n        lastRetainId: 0,\n        invocationQueue: [],\n        invocationQueueMaxLen: 1000,\n        handleInvocationQueueIsScheduled: false\n    };\n\n    var PREFIX_MAGIC_FUNCTION = \"__TRANSIT_JS_FUNCTION_\";\n    var PREFIX_MAGIC_NATIVE_FUNCTION = \"__TRANSIT_NATIVE_FUNCTION_\";\n    var PREFIX_MAGIC_OBJECT = \"__TRANSIT_OBJECT_PROXY_\";\n    var MARKER_MAGIC_OBJECT_GLOBAL = \"__TRANSIT_OBJECT_GLOBAL\";\n    var GLOBAL_OBJECT = window;\n\n    transit.doInvokeNative = function(invocationDescription){\n        throw \"must be replaced by native runtime \" + invocationDescription;\n    };\n\n    /* should be replaced by native runtime to support more efficient solution */\n    /* this behavior is expected: */\n    /*   1. if one call throws an exception, all others must still be executed */\n    /*   2. result is ignored */\n    /*   3. order is not relevant */\n    transit.doHandleInvocationQueue = function(invocationDescriptions){\n        for(var i=0; i<invocationDescriptions.length; i++) {\n            var description = invocationDescriptions[i];\n            try {\n                transit.doInvokeNative(description);\n            } catch(e) {\n            }\n        }\n    };\n    transit.doHandleInvocationQueue.isFallback = true;\n\n    transit.nativeFunction = function(nativeId, options){\n        var f;\n        if(options && options.async) {\n            f = function(){\n                transit.queueNative(nativeId, this, arguments, f.transitNoThis);\n            };\n        } else {\n            f = function(){\n                return transit.invokeNative(nativeId, this, arguments, f.transitNoThis);\n            };\n        }\n        f.transitNoThis = options && options.noThis;\n        f.transitNativeId = PREFIX_MAGIC_NATIVE_FUNCTION + nativeId;\n\n        return f;\n    };\n\n    transit.recursivelyProxifyMissingFunctionProperties = function(missing, existing) {\n        for(var key in existing) {\n            if(existing.hasOwnProperty(key)) {\n                var existingValue = existing[key];\n\n                if(typeof existingValue === \"function\") {\n                    missing[key] = transit.proxify(existingValue);\n                }\n                if(typeof existingValue === \"object\" && typeof missing[key] === \"object\" && missing[key] !== null) {\n                    transit.recursivelyProxifyMissingFunctionProperties(missing[key], existingValue);\n                }\n            }\n        }\n    };\n\n    transit.proxify = function(elem) {\n        if(typeof elem === \"function\") {\n            if(typeof elem.transitNativeId !== \"undefined\") {\n                return elem.transitNativeId;\n            } else {\n                return transit.retainElement(elem);\n            }\n        }\n\n        if(typeof elem === \"object\") {\n            if(elem === GLOBAL_OBJECT) {\n                return MARKER_MAGIC_OBJECT_GLOBAL;\n            }\n            /* when called from native code, typeof ('string') might return 'object' */\n            if(elem != null && [Object, Array, String, Boolean, Number].indexOf(elem.constructor)<0) {\n                return transit.retainElement(elem);\n            }\n\n            var copy;\n            try {\n                copy = JSON.parse(JSON.stringify(elem));\n            } catch (e) {\n                return transit.retainElement(elem);\n            }\n            transit.recursivelyProxifyMissingFunctionProperties(copy, elem);\n            return copy;\n        }\n\n        return elem;\n    };\n\n    transit.createInvocationDescription = function(nativeId, thisArg, args, noThis) {\n        var invocationDescription = {\n            nativeId: nativeId,\n            thisArg: noThis ? null : ((thisArg === GLOBAL_OBJECT) ? null : transit.proxify(thisArg)),\n            args: []\n        };\n\n        for(var i = 0;i<args.length; i++) {\n            invocationDescription.args.push(transit.proxify(args[i]));\n        }\n\n        return invocationDescription;\n    };\n\n    transit.invokeNative = function(nativeId, thisArg, args, noThis) {\n        var invocationDescription = transit.createInvocationDescription(nativeId, thisArg, args, noThis);\n        return transit.doInvokeNative(invocationDescription);\n    };\n\n    transit.handleInvocationQueue = function() {\n        if(transit.handleInvocationQueueIsScheduled) {\n            clearTimeout(transit.handleInvocationQueueIsScheduled);\n            transit.handleInvocationQueueIsScheduled = false;\n        }\n\n        var copy = transit.invocationQueue;\n        transit.invocationQueue = [];\n        transit.doHandleInvocationQueue(copy);\n    };\n\n    transit.queueNative = function(nativeId, thisArg, args) {\n        var invocationDescription = transit.createInvocationDescription(nativeId, thisArg, args);\n        transit.invocationQueue.push(invocationDescription);\n        if(transit.invocationQueue.length >= transit.invocationQueueMaxLen) {\n            transit.handleInvocationQueue();\n        } else {\n            if(!transit.handleInvocationQueueIsScheduled) {\n                transit.handleInvocationQueueIsScheduled = setTimeout(function(){\n                    transit.handleInvocationQueueIsScheduled = false;\n                    transit.handleInvocationQueue();\n                }, 0);\n            }\n        }\n    };\n\n    transit.retainElement = function(element){\n        transit.lastRetainId++;\n        var id = \"\" + transit.lastRetainId;\n        if(typeof element === \"object\") {\n            id = PREFIX_MAGIC_OBJECT + id;\n        }\n        if(typeof element === \"function\") {\n            id = PREFIX_MAGIC_FUNCTION + id;\n        }\n\n        transit.retained[id] = element;\n        return id;\n    };\n\n    transit.r = function(retainId) {\n        return transit.retained[retainId];\n    };\n\n    transit.releaseElementWithId = function(retainId) {\n        if(typeof transit.retained[retainId] === \"undefined\") {\n            throw \"no retained element with Id \" + retainId;\n        }\n\n        delete transit.retained[retainId];\n    };\n\n    window[globalName] = transit;      \n\n})(\"transit\");(function(globalName){\n    var transit = window[globalName];\n\n    var callCount = 0;\n    transit.doInvokeNative = function(invocationDescription){\n        invocationDescription.callNumber = ++callCount;\n        transit.nativeInvokeTransferObject = invocationDescription;\n\n        var iFrame = document.createElement('iframe');\n        iFrame.setAttribute('src', 'transit:/doInvokeNative?c='+callCount);\n\n        /* this call blocks until native code returns */\n        /* native ccde reads from and writes to transit.nativeInvokeTransferObject */\n        document.documentElement.appendChild(iFrame);\n\n        /* free resources */\n        iFrame.parentNode.removeChild(iFrame);\n        iFrame = null;\n\n        if(transit.nativeInvokeTransferObject === invocationDescription) {\n            throw new Error(\"internal error with transit: invocation transfer object not filled.\");\n        }\n        var result = transit.nativeInvokeTransferObject;\n        if(result instanceof Error) {\n            throw result;\n        } else {\n            return result;\n        }\n    };\n\n    transit.doHandleInvocationQueue = function(invocationDescriptions) {\n        callCount++;\n        transit.nativeInvokeTransferObject = invocationDescriptions;\n        var iFrame = document.createElement('iframe');\n        iFrame.setAttribute('src', 'transit:/doHandleInvocationQueue?c='+callCount);\n\n        document.documentElement.appendChild(iFrame);\n\n        iFrame.parentNode.removeChild(iFrame);\n        iFrame = null;\n        transit.nativeInvokeTransferObject = null;\n    };\n\n})(\"transit\");})()"
    // _TRANSIT_JS_RUNTIME_CODE_END
    ;