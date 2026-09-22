#import <Foundation/Foundation.h>
#import <Security/AuthorizationPlugin.h>
#import <sys/stat.h>

@protocol GPBarLoginCaptureProtocol
- (void)capture:(NSString *)username password:(NSString *)password userID:(uint32_t)userID reply:(void (^)(void))reply;
@end

@interface GPBarLoginMarker : NSObject
@end
@implementation GPBarLoginMarker
@end

typedef struct {
    const AuthorizationCallbacks *callbacks;
    AuthorizationEngineRef engine;
} GPBarMechanism;

static NSString *ContextString(GPBarMechanism *mechanism, const char *key, size_t maximum) {
    const AuthorizationValue *value = NULL;
    if (mechanism->callbacks->GetContextValue(mechanism->engine, key, NULL, &value) != errSecSuccess ||
        !value || !value->data || value->length == 0 || value->length > maximum + 1) return nil;
    size_t length = value->length;
    const char *bytes = value->data;
    if (bytes[length - 1] == '\0') length--;
    if (length == 0 || length > maximum || memchr(bytes, '\0', length)) return nil;
    return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
}

static void Capture(GPBarMechanism *mechanism) {
    if (geteuid() != 0) return;
    const AuthorizationValue *value = NULL;
    if (mechanism->callbacks->GetContextValue(mechanism->engine, "uid", NULL, &value) != errSecSuccess ||
        !value || !value->data || value->length != sizeof(uid_t)) return;
    uid_t userID;
    memcpy(&userID, value->data, sizeof(userID));
    if (userID < 501) return;

    NSString *path = @"/Library/Application Support/GPBar/LoginSSO/users.plist";
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_uid != 0 || (info.st_mode & 077) != 0 || info.st_size > 65536) return;
    NSDictionary *users = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    if (![users[@(userID).stringValue] isKindOfClass:NSString.class]) return;

    NSString *username = ContextString(mechanism, kAuthorizationEnvironmentUsername, 1024);
    NSString *password = ContextString(mechanism, kAuthorizationEnvironmentPassword, 4096);
    if (!username || !password) return;
    NSString *team = [[NSBundle bundleForClass:GPBarLoginMarker.class] objectForInfoDictionaryKey:@"GPBarSigningTeam"];
    if (![team isKindOfClass:NSString.class] || team.length != 10 ||
        [team rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet]].location != NSNotFound) return;
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:@"com.beeltec.GPBar.helper" options:NSXPCConnectionPrivileged];
    [connection setCodeSigningRequirement:[NSString stringWithFormat:@"anchor apple generic and identifier \"com.beeltec.GPBar.helper\" and certificate leaf[subject.OU] = \"%@\"", team]];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(GPBarLoginCaptureProtocol)];
    [connection resume];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    id<GPBarLoginCaptureProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_semaphore_signal(completed);
    }];
    [proxy capture:username password:password userID:userID reply:^{ dispatch_semaphore_signal(completed); }];
    // A stopped helper must not prevent macOS login.
    dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
    [connection invalidate];
}

static OSStatus PluginDestroy(AuthorizationPluginRef plugin) { return errSecSuccess; }

static OSStatus MechanismCreate(AuthorizationPluginRef plugin, AuthorizationEngineRef engine,
                                AuthorizationMechanismId identifier, AuthorizationMechanismRef *result) {
    if (strcmp(identifier, "capture") != 0) return errAuthorizationInternal;
    GPBarMechanism *mechanism = calloc(1, sizeof(GPBarMechanism));
    if (!mechanism) return errAuthorizationInternal;
    mechanism->callbacks = plugin;
    mechanism->engine = engine;
    *result = mechanism;
    return errSecSuccess;
}

static OSStatus MechanismInvoke(AuthorizationMechanismRef reference) {
    GPBarMechanism *mechanism = reference;
    @autoreleasepool {
        @try { Capture(mechanism); } @catch (NSException *exception) { }
    }
    return mechanism->callbacks->SetResult(mechanism->engine, kAuthorizationResultAllow);
}

static OSStatus MechanismDeactivate(AuthorizationMechanismRef reference) {
    GPBarMechanism *mechanism = reference;
    return mechanism->callbacks->DidDeactivate(mechanism->engine);
}

static OSStatus MechanismDestroy(AuthorizationMechanismRef reference) { free(reference); return errSecSuccess; }

OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks, AuthorizationPluginRef *plugin,
                                   const AuthorizationPluginInterface **interface) {
    static const AuthorizationPluginInterface implementation = {
        kAuthorizationPluginInterfaceVersion, PluginDestroy, MechanismCreate, MechanismInvoke,
        MechanismDeactivate, MechanismDestroy
    };
    *plugin = (void *)callbacks;
    *interface = &implementation;
    return errSecSuccess;
}
