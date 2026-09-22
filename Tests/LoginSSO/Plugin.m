#import "../../GPBarLoginPlugin/LoginPlugin.m"

static AuthorizationValue currentValue;
static unsigned allows;
static unsigned deactivations;
static OSStatus GetContext(AuthorizationEngineRef engine, AuthorizationString key,
                           AuthorizationContextFlags *flags, const AuthorizationValue **value) {
    *value = &currentValue;
    return errSecSuccess;
}
static OSStatus SetResult(AuthorizationEngineRef engine, AuthorizationResult result) {
    assert(result == kAuthorizationResultAllow);
    allows++;
    return errSecSuccess;
}
static OSStatus Deactivate(AuthorizationEngineRef engine) { deactivations++; return errSecSuccess; }

int main(void) {
    @autoreleasepool {
        AuthorizationCallbacks callbacks = { .version = kAuthorizationCallbacksVersion,
            .SetResult = SetResult, .DidDeactivate = Deactivate, .GetContextValue = GetContext };
        AuthorizationPluginRef plugin;
        const AuthorizationPluginInterface *interface;
        assert(AuthorizationPluginCreate(&callbacks, &plugin, &interface) == errSecSuccess);
        AuthorizationMechanismRef mechanism;
        AuthorizationEngineRef engine = (AuthorizationEngineRef)&callbacks;
        assert(interface->MechanismCreate(plugin, engine, "unknown", &mechanism) != errSecSuccess);
        assert(interface->MechanismCreate(plugin, engine, "capture", &mechanism) == errSecSuccess);
        currentValue = (AuthorizationValue){ 8, "fixture" };
        assert([ContextString(mechanism, "password", 4096) isEqualToString:@"fixture"]);
        currentValue = (AuthorizationValue){ 7, "fixture" };
        assert([ContextString(mechanism, "password", 4096) isEqualToString:@"fixture"]);
        currentValue = (AuthorizationValue){ 8, "bad\0data" };
        assert(ContextString(mechanism, "password", 4096) == nil);
        currentValue = (AuthorizationValue){ 2, "\xff\xff" };
        assert(ContextString(mechanism, "password", 4096) == nil);
        currentValue = (AuthorizationValue){ 9000, "fixture" };
        assert(ContextString(mechanism, "password", 4096) == nil);
        currentValue = (AuthorizationValue){ 0, NULL };
        assert(ContextString(mechanism, "password", 4096) == nil);
        assert(interface->MechanismInvoke(mechanism) == errSecSuccess && allows == 1);
        assert(interface->MechanismDeactivate(mechanism) == errSecSuccess && deactivations == 1);
        assert(interface->MechanismDestroy(mechanism) == errSecSuccess);
        assert(interface->PluginDestroy(plugin) == errSecSuccess);
        puts("PASS: plug-in ABI, bounded UTF-8 context parsing, fail-open invocation, and teardown");
    }
    return 0;
}
