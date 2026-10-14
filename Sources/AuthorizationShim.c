#include <Security/Authorization.h>
#include <stdio.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus TCCAuthorizationExecuteWithPrivileges(
    AuthorizationRef authorization,
    const char *pathToTool,
    char * const *arguments,
    FILE **communicationsPipe
) {
    return AuthorizationExecuteWithPrivileges(
        authorization,
        pathToTool,
        0,
        arguments,
        communicationsPipe
    );
}
#pragma clang diagnostic pop
