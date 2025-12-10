#include <unistd.h>
#include <string.h>

int main() {
    const char *msg = "Hello, World! (from static C binary)\n";
    write(1, msg, strlen(msg));
    return 0;
}
