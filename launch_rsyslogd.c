#include <unistd.h>

int main(int argc, char *argv[])
{
    return execl("/usr/sbin/rsyslogd", "rsyslogd", "-n", NULL);
}
