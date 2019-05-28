// Shadow by jjolano

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Includes/Shadow.h"

Shadow *_shadow = nil;
NSArray *dyld_array = nil;

// Stable Hooks
%group hook_libc
// #include "Hooks/Stable/libc.xm"
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>
#include <spawn.h>
#include <fcntl.h>
#include <errno.h>

%hookf(int, access, const char *pathname, int mode) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    // workaround for tweaks not loading properly in Substrate
    if([_shadow useInjectCompatibilityMode] && [[path pathExtension] isEqualToString:@"plist"] && [path containsString:@"DynamicLibraries/"]) {
        return %orig;
    }

    if([_shadow isPathRestricted:path]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}

%hookf(char *, getenv, const char *name) {
    if(!name) {
        return %orig;
    }

    NSString *env = [NSString stringWithUTF8String:name];

    if([env isEqualToString:@"DYLD_INSERT_LIBRARIES"]
    || [env isEqualToString:@"_MSSafeMode"]
    || [env isEqualToString:@"_SafeMode"]) {
        return NULL;
    }

    return %orig;
}

%hookf(FILE *, fopen, const char *pathname, const char *mode) {
    if(!pathname) {
        return %orig;
    }
    
    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return NULL;
    }

    return %orig;
}

%hookf(int, stat, const char *pathname, struct stat *statbuf) {
    if(!pathname) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}

%hookf(int, lstat, const char *pathname, struct stat *statbuf) {
    if(!pathname) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}

%hookf(int, statfs, const char *path, struct statfs *buf) {
    if(!path) {
        return %orig;
    }

    int ret = %orig;

    if(ret == 0) {
        NSString *pathname = [NSString stringWithUTF8String:path];

        pathname = [_shadow resolveLinkInPath:pathname];
        
        if(![pathname hasPrefix:@"/var"]
        && ![pathname hasPrefix:@"/private/var"]) {
            if(buf) {
                // Ensure root is marked read-only.
                buf->f_flags |= MNT_RDONLY;
                return ret;
            }
        }

        if([_shadow isPathRestricted:pathname]) {
            errno = ENOENT;
            return -1;
        }
    }

    return ret;
}

%hookf(int, posix_spawn, pid_t *pid, const char *pathname, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    if([_shadow isPathRestricted:path]) {
        return ENOSYS;
    }

    return %orig;
}

%hookf(int, posix_spawnp, pid_t *pid, const char *pathname, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    if([_shadow isPathRestricted:path]) {
        return ENOSYS;
    }

    return %orig;
}

%hookf(char *, realpath, const char *pathname, char *resolved_path) {
    if(!pathname) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return NULL;
    }

    return %orig;
}

%hookf(int, symlink, const char *path1, const char *path2) {
    if(!path1 || !path2) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:path2]]) {
        errno = ENOENT;
        return -1;
    }

    int ret = %orig;

    if(ret == 0) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[NSString stringWithUTF8String:path1] toPath:[NSString stringWithUTF8String:path2]];
    }

    return ret;
}

%hookf(int, link, const char *path1, const char *path2) {
    if(!path1 || !path2) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:path2]]) {
        errno = ENOENT;
        return -1;
    }

    int ret = %orig;

    if(ret == 0) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[NSString stringWithUTF8String:path1] toPath:[NSString stringWithUTF8String:path2]];
    }

    return ret;
}

%hookf(int, fstatat, int fd, const char *pathname, struct stat *buf, int flag) {
    if(!pathname) {
        return %orig;
    }

    BOOL restricted = NO;
    char cfdpath[PATH_MAX];
    
    if(fcntl(fd, F_GETPATH, cfdpath) != -1) {
        NSString *fdpath = [NSString stringWithUTF8String:cfdpath];
        NSString *path = [NSString stringWithUTF8String:pathname];

        restricted = [_shadow isPathRestricted:fdpath];

        if(!restricted && [fdpath isEqualToString:@"/"]) {
            restricted = [_shadow isPathRestricted:[NSString stringWithFormat:@"/%@", path]];
        }
    }

    if(restricted) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}
%end

%group hook_NSFileHandle
// #include "Hooks/Stable/NSFileHandle.xm"
%hook NSFileHandle
+ (instancetype)fileHandleForReadingAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForReadingFromURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForWritingAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForWritingToURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForUpdatingAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForUpdatingURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}
%end
%end

%group hook_NSFileManager
// #include "Hooks/Stable/NSFileManager.xm"
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isReadableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isWritableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isDeletableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isExecutableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (NSDirectoryEnumerator<NSURL *> *)enumeratorAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask errorHandler:(BOOL (^)(NSURL *url, NSError *error))handler {
    if([_shadow isURLRestricted:url]) {
        return %orig([NSURL fileURLWithPath:@"file:///.file"], keys, mask, handler);
    }

    return %orig;
}

- (NSDirectoryEnumerator<NSString *> *)enumeratorAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return %orig(@"/.file");
    }

    return %orig;
}

- (NSArray<NSString *> *)subpathsOfDirectoryAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (NSArray<NSString *> *)subpathsAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return nil;
    }

    return %orig;
}

- (BOOL)copyItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:srcURL]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:srcPath manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (NSArray<NSString *> *)componentsToDisplayForPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return nil;
    }

    return %orig;
}

- (NSString *)displayNameAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return path;
    }

    return %orig;
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (NSData *)contentsAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return nil;
    }

    return %orig;
}

- (BOOL)contentsEqualAtPath:(NSString *)path1 andPath:(NSString *)path2 {
    if([_shadow isPathRestricted:path1] || [_shadow isPathRestricted:path2]) {
        return NO;
    }

    return %orig;
}

- (BOOL)getRelationship:(NSURLRelationship *)outRelationship ofDirectoryAtURL:(NSURL *)directoryURL toItemAtURL:(NSURL *)otherURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:directoryURL] || [_shadow isURLRestricted:otherURL]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)getRelationship:(NSURLRelationship *)outRelationship ofDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domainMask toItemAtURL:(NSURL *)otherURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:otherURL]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)changeCurrentDirectoryPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)createSymbolicLinkAtURL:(NSURL *)url withDestinationURL:(NSURL *)destURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:destURL]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[url path] toPath:[destURL path]];
    }

    return ret;
}

- (BOOL)createSymbolicLinkAtPath:(NSString *)path withDestinationPath:(NSString *)destPath error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:destPath]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:path toPath:destPath];
    }

    return ret;
}

- (BOOL)linkItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:dstURL]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[srcURL path] toPath:[dstURL path]];
    }

    return ret;
}

- (BOOL)linkItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:dstPath]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:srcPath toPath:dstPath];
    }

    return ret;
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}
%end
%end

%group hook_NSURL
// #include "Hooks/Stable/NSURL.xm"
%hook NSURL
- (BOOL)checkResourceIsReachableAndReturnError:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}
%end
%end

%group hook_UIApplication
// #include "Hooks/Stable/UIApplication.xm"
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if([_shadow isURLRestricted:url]) {
        return NO;
    }

    return %orig;
}
%end
%end

%group hook_NSBundle
// #include "Hooks/Testing/NSBundle.xm"
%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if([key isEqualToString:@"SignerIdentity"]) {
        return nil;
    }

    return %orig;
}
%end
%end

// Other Hooks
%group hook_private
// #include "Hooks/ApplePrivate.xm"
#include <unistd.h>
#include "Includes/codesign.h"

%hookf(int, csops, pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    int ret = %orig;

    if(ops == CS_OPS_STATUS && (ret & CS_PLATFORM_BINARY) && pid == getpid()) {
        // Ensure that the platform binary flag is not set.
        ret &= ~CS_PLATFORM_BINARY;
    }

    return ret;
}
%end

%group hook_debugging
// #include "Hooks/Debugging.xm"
#include <sys/sysctl.h>
#include <unistd.h>

%hookf(int, sysctl, int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = %orig;

    if(ret == 0
    && name[0] == CTL_KERN
    && name[1] == KERN_PROC
    && name[2] == KERN_PROC_PID
    && name[3] == getpid()) {
        // Remove trace flag.
        if(oldp) {
            struct kinfo_proc *p = ((struct kinfo_proc *) oldp);

            if(p->kp_proc.p_flag & P_TRACED) {
                p->kp_proc.p_flag &= ~P_TRACED;
            }
        }
    }

    return ret;
}

%hookf(pid_t, getppid) {
    return 1;
}

%hookf(int, "_ptrace", int request, pid_t pid, caddr_t addr, int data) {
    if(request == 31 /* PTRACE_DENY_ATTACH */) {
        // "Success"
        return 0;
    }

    return %orig;
}
%end

%group hook_dyld_image
// #include "Hooks/dyld.xm"
#include <mach-o/dyld.h>

%hookf(uint32_t, _dyld_image_count) {
    if(dyld_array) {
        return (uint32_t) [dyld_array count];
    }

    return %orig;
}

%hookf(const char *, _dyld_get_image_name, uint32_t image_index) {
    if(dyld_array) {
        if(image_index >= (uint32_t) [dyld_array count]) {
            return NULL;
        }

        return %orig((uint32_t) [dyld_array[image_index] unsignedIntValue]);
    }

    // Basic filter.
    const char *ret = %orig;

    if(ret && [_shadow isImageRestricted:[NSString stringWithUTF8String:ret]]) {
        return %orig(0);
    }

    return ret;
}
%end

%group hook_dyld_dlsym
// #include "Hooks/dlsym.xm"
#include <dlfcn.h>

%hookf(void *, dlsym, void *handle, const char *symbol) {
    if(!symbol) {
        return %orig;
    }

    NSString *sym = [NSString stringWithUTF8String:symbol];

    if([sym hasPrefix:@"MS"] /* Substrate */
    || [sym hasPrefix:@"Sub"] /* Substitute */
    || [sym hasPrefix:@"PS"] /* Substitrate */) {
        NSLog(@"blocked dlsym lookup: %@", sym);
        return NULL;
    }

    return %orig;
}
%end

%group hook_sandbox
// #include "Hooks/Sandbox.xm"
#include <stdio.h>
#include <unistd.h>
#include <pwd.h>

%hookf(pid_t, fork) {
    errno = ENOSYS;
    return -1;
}

%hookf(FILE *, popen, const char *command, const char *type) {
    errno = ENOSYS;
    return NULL;
}

%hookf(int, setgid, gid_t gid) {
    // Block setgid for root.
    if(gid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, setuid, uid_t uid) {
    // Block setuid for root.
    if(uid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, setegid, gid_t gid) {
    // Block setegid for root.
    if(gid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, seteuid, uid_t uid) {
    // Block seteuid for root.
    if(uid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(uid_t, getuid) {
    // Return uid for mobile.
    struct passwd *pw = getpwnam("mobile");
    return pw ? pw->pw_uid : 501;
}

%hookf(gid_t, getgid) {
    // Return gid for mobile.
    struct passwd *pw = getpwnam("mobile");
    return pw ? pw->pw_gid : 501;
}

%hookf(uid_t, geteuid) {
    // Return uid for mobile.
    struct passwd *pw = getpwnam("mobile");
    return pw ? pw->pw_uid : 501;
}

%hookf(uid_t, getegid) {
    // Return gid for mobile.
    struct passwd *pw = getpwnam("mobile");
    return pw ? pw->pw_gid : 501;
}

%hookf(int, setreuid, uid_t ruid, uid_t euid) {
    // Block for root.
    if(ruid == 0 || euid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, setregid, gid_t rgid, gid_t egid) {
    // Block for root.
    if(rgid == 0 || egid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}
%end

%group hook_libraries
%hook UIDevice
+ (BOOL)isJailbroken {
    return NO;
}

- (BOOL)isJailBreak {
    return NO;
}

- (BOOL)isJailBroken {
    return NO;
}
%end

// %hook SFAntiPiracy
// + (int)isJailbroken {
// 	// Probably should not hook with a hard coded value.
// 	// This value may be changed by developers using this library.
// 	// Best to defeat the checks rather than skip them.
// 	return 4783242;
// }
// %end

%hook JailbreakDetectionVC
- (BOOL)isJailbroken {
    return NO;
}
%end

%hook DTTJailbreakDetection
+ (BOOL)isJailbroken {
    return NO;
}
%end

%hook ANSMetadata
- (BOOL)computeIsJailbroken {
    return NO;
}

- (BOOL)isJailbroken {
    return NO;
}
%end

%hook AppsFlyerUtils
+ (BOOL)isJailBreakon {
    return NO;
}
%end

%hook GBDeviceInfo
- (BOOL)isJailbroken {
    return NO;
}
%end

%hook CMARAppRestrictionsDelegate
- (bool)isDeviceNonCompliant {
    return false;
}
%end

%hook ADYSecurityChecks
+ (bool)isDeviceJailbroken {
    return false;
}
%end

%hook UBReportMetadataDevice
- (void *)is_rooted {
    return NULL;
}
%end

%hook UtilitySystem
+ (bool)isJailbreak {
    return false;
}
%end

%hook GemaltoConfiguration
+ (bool)isJailbreak {
    return false;
}
%end

%hook CPWRDeviceInfo
- (bool)isJailbroken {
    return false;
}
%end

%hook CPWRSessionInfo
- (bool)isJailbroken {
    return false;
}
%end

%hook KSSystemInfo
+ (bool)isJailbroken {
    return false;
}
%end

%hook EMDSKPPConfiguration
- (bool)jailBroken {
    return false;
}
%end

%hook EnrollParameters
- (void *)jailbroken {
    return NULL;
}
%end

%hook EMDskppConfigurationBuilder
- (bool)jailbreakStatus {
    return false;
}
%end

%hook FCRSystemMetadata
- (bool)isJailbroken {
    return false;
}
%end

%hook v_VDMap
- (bool)isJailBrokenDetectedByVOS {
    return false;
}
%end
%end

void init_path_map(Shadow *shadow) {
    // Restrict / by whitelisting
    [shadow addPath:@"/" restricted:YES];
    [shadow addPath:@"/.file" restricted:NO];
    [shadow addPath:@"/AppleInternal" restricted:NO];
    [shadow addPath:@"/Applications" restricted:NO];
    [shadow addPath:@"/bin" restricted:YES];
    [shadow addPath:@"/boot" restricted:NO];
    [shadow addPath:@"/cores" restricted:NO];
    [shadow addPath:@"/dev" restricted:NO];
    [shadow addPath:@"/Developer" restricted:NO];
    [shadow addPath:@"/lib" restricted:NO];
    [shadow addPath:@"/mnt" restricted:NO];
    [shadow addPath:@"/private" restricted:NO];
    [shadow addPath:@"/sbin" restricted:YES];

    // Restrict /etc
    [shadow addPath:@"/etc" restricted:NO];
    [shadow addPath:@"/etc/." restricted:YES];
    [shadow addPath:@"/etc/apt" restricted:YES];
    [shadow addPath:@"/etc/dpkg" restricted:YES];
    [shadow addPath:@"/etc/ssh" restricted:YES];
    [shadow addPath:@"/etc/dropbear" restricted:YES];
    [shadow addPath:@"/etc/rc.d" restricted:YES];
    [shadow addPath:@"/etc/pam.d" restricted:YES];
    [shadow addPath:@"/etc/default" restricted:YES];
    [shadow addPath:@"/etc/motd" restricted:YES];
    
    // Restrict /Library by whitelisting
    [shadow addPath:@"/Library" restricted:YES];
    [shadow addPath:@"/Library/Application Support" restricted:YES];
    [shadow addPath:@"/Library/Application Support/AggregateDictionary" restricted:NO];
    [shadow addPath:@"/Library/Application Support/BTServer" restricted:NO];
    [shadow addPath:@"/Library/Audio" restricted:NO];
    [shadow addPath:@"/Library/Caches" restricted:NO];
    [shadow addPath:@"/Library/Filesystems" restricted:NO];
    [shadow addPath:@"/Library/Internet Plug-Ins" restricted:NO];
    [shadow addPath:@"/Library/Keychains" restricted:NO];
    [shadow addPath:@"/Library/LaunchAgents" restricted:NO];
    [shadow addPath:@"/Library/Logs" restricted:NO];
    [shadow addPath:@"/Library/Managed Preferences" restricted:NO];
    [shadow addPath:@"/Library/MobileDevice" restricted:NO];
    [shadow addPath:@"/Library/MusicUISupport" restricted:NO];
    [shadow addPath:@"/Library/Preferences" restricted:NO];
    [shadow addPath:@"/Library/Printers" restricted:NO];
    [shadow addPath:@"/Library/Ringtones" restricted:NO];
    [shadow addPath:@"/Library/Updates" restricted:NO];
    [shadow addPath:@"/Library/Wallpaper" restricted:NO];
    
    // Restrict /tmp
    [shadow addPath:@"/tmp" restricted:NO];
    [shadow addPath:@"/tmp/substrate" restricted:YES];
    [shadow addPath:@"/tmp/Substrate" restricted:YES];
    [shadow addPath:@"/tmp/cydia.log" restricted:YES];
    [shadow addPath:@"/tmp/syslog" restricted:YES];
    [shadow addPath:@"/tmp/slide.txt" restricted:YES];
    [shadow addPath:@"/tmp/amfidebilitate.out" restricted:YES];
    
    // Restrict /User
    [shadow addPath:@"/User" restricted:NO];
    [shadow addPath:@"/User/Library/Cydia" restricted:YES];
    [shadow addPath:@"/User/Library/Logs/Cydia" restricted:YES];
    [shadow addPath:@"/User/Library/SBSettings" restricted:YES];
    [shadow addPath:@"/User/Library/Preferences" restricted:YES];
    [shadow addPath:@"/User/Library/Preferences/com.apple." restricted:NO];
    [shadow addPath:@"/User/Media/panguaxe" restricted:YES];

    // Restrict /usr
    [shadow addPath:@"/usr" restricted:NO];
    [shadow addPath:@"/usr/bin" restricted:YES];
    [shadow addPath:@"/usr/include" restricted:YES];
    [shadow addPath:@"/usr/lib" restricted:YES];
    [shadow addPath:@"/usr/libexec" restricted:YES];
    [shadow addPath:@"/usr/local" restricted:YES];
    [shadow addPath:@"/usr/sbin" restricted:YES];
    [shadow addPath:@"/usr/share/dpkg" restricted:YES];
    [shadow addPath:@"/usr/share/gnupg" restricted:YES];
    [shadow addPath:@"/usr/share/bigboss" restricted:YES];
    [shadow addPath:@"/usr/share/jailbreak" restricted:YES];
    [shadow addPath:@"/usr/share/entitlements" restricted:YES];
    [shadow addPath:@"/usr/share/tabset" restricted:YES];
    [shadow addPath:@"/usr/share/terminfo" restricted:YES];
    
    // Restrict /var
    [shadow addPath:@"/var" restricted:NO];
    [shadow addPath:@"/var/cache/apt" restricted:YES];
    [shadow addPath:@"/var/lib" restricted:YES];
    [shadow addPath:@"/var/stash" restricted:YES];
    [shadow addPath:@"/var/db/stash" restricted:YES];
    [shadow addPath:@"/var/rocket_stashed" restricted:YES];
    [shadow addPath:@"/var/tweak" restricted:YES];
    [shadow addPath:@"/var/LIB" restricted:YES];
    [shadow addPath:@"/var/ulb" restricted:YES];
    [shadow addPath:@"/var/bin" restricted:YES];
    [shadow addPath:@"/var/sbin" restricted:YES];
    [shadow addPath:@"/var/profile" restricted:YES];
    [shadow addPath:@"/var/motd" restricted:YES];
    [shadow addPath:@"/var/dropbear" restricted:YES];
    [shadow addPath:@"/var/run" restricted:YES];

    // Restrict /System
    [shadow addPath:@"/System" restricted:NO];
    [shadow addPath:@"/System/Library/PreferenceBundles/AppList.bundle" restricted:YES];
}

// SpringBoard hook
%group hook_springboard
%hook SpringBoard
- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig;

    // Generate file map.
    Shadow *shadow = [Shadow new];

    if(shadow) {
        [shadow generateFileMap];
    } else {
        NSLog(@"failed to initialize Shadow");
    }
}
%end
%end

%ctor {
    NSBundle *bundle = [NSBundle mainBundle];

    if(bundle != nil) {
        NSString *executablePath = [bundle executablePath];
        NSString *bundleIdentifier = [bundle bundleIdentifier];

        // Load preferences file
        NSMutableDictionary *prefs = [[NSMutableDictionary alloc] initWithContentsOfFile:PREFS_PATH];

        if(!prefs) {
            // Create new preferences file
            prefs = [NSMutableDictionary new];
            [prefs writeToFile:PREFS_PATH atomically:YES];
        }

        // Check if Shadow is enabled
        if(prefs[@"enabled"] && ![prefs[@"enabled"] boolValue]) {
            // Shadow disabled in preferences
            return;
        }

        // Check if safe bundleIdentifier
        if(prefs[@"exclude_system_apps"]) {
            // Disable Shadow for Apple and jailbreak apps
            NSArray *excluded_bundleids = @[
                @"com.apple", // Apple apps
                @"is.workflow.my.app", // Shortcuts
                @"science.xnu.undecimus", // unc0ver
                @"com.electrateam.chimera", // Chimera
                @"org.coolstar.electra" // Electra
            ];

            for(NSString *bundle_id in excluded_bundleids) {
                if([bundleIdentifier hasPrefix:bundle_id]) {
                    return;
                }
            }
        }

        // Check if excluded bundleIdentifier
        if(prefs[@"mode"]) {
            if([prefs[@"mode"] isEqualToString:@"whitelist"]) {
                // Whitelist - disable Shadow if not enabled for this bundleIdentifier
                if(!prefs[bundleIdentifier] || ![prefs[bundleIdentifier] boolValue]) {
                    return;
                }
            } else {
                // Blacklist - disable Shadow if enabled for this bundleIdentifier
                if(prefs[bundleIdentifier] && [prefs[bundleIdentifier] boolValue]) {
                    return;
                }
            }
        }

        // Set default settings
        if(!prefs[@"dyld_hooks_enabled"]) {
            prefs[@"dyld_hooks_enabled"] = @YES;
        }

        if(!prefs[@"inject_compatibility_mode"]) {
            prefs[@"inject_compatibility_mode"] = @YES;
        }

        // SpringBoard
        if([bundleIdentifier isEqualToString:@"com.apple.SpringBoard"]) {
            if(prefs[@"auto_file_map_generation_enabled"] && [prefs[@"auto_file_map_generation_enabled"] boolValue]) {
                %init(hook_springboard);
            }

            return;
        }

        // System Applications
        if([executablePath hasPrefix:@"/Applications"]) {
            return;
        }

        // User (Sandboxed) Applications
        if([executablePath hasPrefix:@"/var/containers/Bundle/Application"]) {
            NSLog(@"bundleIdentifier: %@", bundleIdentifier);

            // Initialize Shadow
            _shadow = [Shadow new];

            if(!_shadow) {
                NSLog(@"failed to initialize Shadow");
                return;
            }

            // Initialize restricted path map
            init_path_map(_shadow);
            NSLog(@"initialized internal path map");

            // Initialize file map
            if(prefs[@"file_map"]) {
                [_shadow addPathsFromFileMap:prefs[@"file_map"]];

                NSLog(@"initialized file map");
            }

            // Compatibility mode
            NSString *bundleIdentifier_compat = [NSString stringWithFormat:@"tweak_compat%@", bundleIdentifier];

            [_shadow setUseTweakCompatibilityMode:YES];

            if(prefs[bundleIdentifier_compat] && [prefs[bundleIdentifier_compat] boolValue]) {
                [_shadow setUseTweakCompatibilityMode:NO];
            }

            if([_shadow useTweakCompatibilityMode]) {
                NSLog(@"using tweak compatibility mode");
            }

            if(prefs[@"inject_compatibility_mode"]) {
                [_shadow setUseInjectCompatibilityMode:[prefs[@"inject_compatibility_mode"] boolValue]];

                // Disable this if we are using Substitute.
                if([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/lib/libsubstitute.dylib"]) {
                    [_shadow setUseInjectCompatibilityMode:NO];
                }

                if([_shadow useInjectCompatibilityMode]) {
                    NSLog(@"using injection compatibility mode");
                }
            }

            // Initialize stable hooks
            %init(hook_libc);
            %init(hook_NSFileHandle);
            %init(hook_NSFileManager);
            %init(hook_NSURL);
            %init(hook_UIApplication);
            %init(hook_NSBundle);
            %init(hook_libraries);
            %init(hook_private);
            %init(hook_debugging);

            NSLog(@"hooked bypass methods");

            // Initialize other hooks
            if(prefs[@"dyld_hooks_enabled"] && [prefs[@"dyld_hooks_enabled"] boolValue]) {
                %init(hook_dyld_image);

                NSLog(@"hooked dyld image methods");
            }

            NSString *bundleIdentifier_dlfcn = [NSString stringWithFormat:@"dlfcn%@", bundleIdentifier];

            if(prefs[bundleIdentifier_dlfcn] && [prefs[bundleIdentifier_dlfcn] boolValue]) {
                %init(hook_dyld_dlsym);

                NSLog(@"hooked dynamic linker methods");
            }

            if(prefs[@"sandbox_hooks_enabled"] && [prefs[@"sandbox_hooks_enabled"] boolValue]) {
                %init(hook_sandbox);

                NSLog(@"hooked sandbox methods");
            }

            if(prefs[@"dyld_filter_enabled"] && [prefs[@"dyld_filter_enabled"] boolValue]) {
                // Generate filtered dyld array
                uint32_t orig_count = _dyld_image_count();

                dyld_array = [_shadow generateDyldArray];

                NSLog(@"generated dyld array (%d/%d)", (uint32_t) [dyld_array count], orig_count);
            }

            NSLog(@"ready");
        }
    }
}
