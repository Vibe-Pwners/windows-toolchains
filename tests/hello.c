#include <windows.h>
#include <stdio.h>

int main(void) {
    printf("hello from mingw-ucrt (C)\n");
    /* Reference a Win32 API symbol so we exercise the headers + import libs. */
    if (GetTickCount() == 0) {
        MessageBoxA(NULL, "hello", "mingw-ucrt", MB_OK);
    }
    return 0;
}
