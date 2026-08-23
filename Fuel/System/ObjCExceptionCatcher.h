#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Domain of the `NSError`s synthesized from a caught `NSException`.
extern NSErrorDomain const FuelObjCExceptionErrorDomain;
/// `userInfo` key holding the original exception's `name`.
extern NSErrorUserInfoKey const FuelObjCExceptionNameKey;

/// Bridges Objective-C exceptions into the Swift error world.
///
/// Some Foundation/Core Data entry points — notably
/// `-[NSPersistentStoreCoordinator addPersistentStoreWithDescription:]`, which
/// SwiftData calls while building a `ModelContainer` — signal unrecoverable
/// store problems by *raising* an `NSException` rather than by returning an
/// `NSError`. Swift's `try`/`catch` cannot see those, so a corrupt store
/// aborts the process before any recovery UI can run. Running the offending
/// call through this shim turns the exception into an ordinary Swift error.
///
/// Recovering from an `NSException` is only safe when the surrounding code is
/// prepared to abandon whatever the block was doing (as the app's startup path
/// is: it falls back to an in-memory store and shows a failure screen). Do not
/// use this to paper over exceptions in code that must keep running.
@interface ObjCExceptionCatcher : NSObject

/// Runs `block`, trapping any `NSException` it raises.
///
/// - Returns: `YES` if `block` completed, `NO` if it raised. On `NO`, `error`
///   is populated with a `FuelObjCExceptionErrorDomain` error whose localized
///   description is the exception's reason.
+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block
                 error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
