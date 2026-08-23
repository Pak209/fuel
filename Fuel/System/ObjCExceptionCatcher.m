#import "ObjCExceptionCatcher.h"

NSErrorDomain const FuelObjCExceptionErrorDomain = @"FuelObjCException";
NSErrorUserInfoKey const FuelObjCExceptionNameKey = @"FuelObjCExceptionName";

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block
                 error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name ?: @"Unknown Objective-C exception";
            userInfo[FuelObjCExceptionNameKey] = exception.name;
            *error = [NSError errorWithDomain:FuelObjCExceptionErrorDomain code:1 userInfo:userInfo];
        }
        return NO;
    }
}

@end
