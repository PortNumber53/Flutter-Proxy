/*
 * shutdownd -- a tiny static HTTP endpoint that powers the dongle down cleanly.
 *
 * The dongle is normally unplugged by pulling car power, which yanks the SD card
 * mid-write. This gives the phone app a way to ask for a real shutdown first.
 *
 *   GET  /ping      -> 200 {"status":"ok",...}   (liveness, never destructive)
 *   POST /shutdown  -> 200, then sync(2) + poweroff
 *
 * Shutdown is POST-only on purpose: a GET would let a stray link prefetch, a
 * browser probing for a captive portal, or a mistyped URL power off the car's
 * head-unit link. A token may be required in addition (see AAWG_EXTRA_SHUTDOWN_
 * TOKEN); supply it as an X-Auth-Token header or ?token= query parameter.
 *
 * usage: shutdownd <bind-ip> <port> [token]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/time.h>
#include <sys/reboot.h>

static const char *token = NULL;

static void say(int c, const char *status, const char *body) {
	char out[512];
	int n = snprintf(out, sizeof out,
		"HTTP/1.1 %s\r\nContent-Type: application/json\r\n"
		"Content-Length: %zu\r\nConnection: close\r\n\r\n%s",
		status, strlen(body), body);
	send(c, out, (size_t)n, 0);
}

/* Constant-time compare so a token cannot be recovered byte-by-byte by timing. */
static int token_ok(const char *req) {
	if (!token || !*token) return 1;               /* no token configured */
	const char *p = strstr(req, "X-Auth-Token:");
	size_t skip = 13;
	if (!p) { p = strstr(req, "token="); skip = 6; }
	if (!p) return 0;
	p += skip;
	while (*p == ' ') p++;
	size_t n = strlen(token);
	unsigned char diff = 0;
	for (size_t i = 0; i < n; i++) diff |= (unsigned char)(p[i] ^ token[i]);
	char end = p[n];
	if (end != '\0' && end != '\r' && end != '\n' && end != ' ' && end != '&') diff |= 1;
	return diff == 0;
}

int main(int argc, char **argv) {
	if (argc < 3 || argc > 4) {
		fprintf(stderr, "usage: %s <bind-ip> <port> [token]\n", argv[0]);
		return 2;
	}
	if (argc == 4 && *argv[3]) token = argv[3];
	signal(SIGPIPE, SIG_IGN);
	signal(SIGCHLD, SIG_IGN);

	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0) { perror("shutdownd: socket"); return 1; }
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((unsigned short)atoi(argv[2]));
	if (inet_pton(AF_INET, argv[1], &a.sin_addr) != 1) {
		fprintf(stderr, "shutdownd: bad bind address %s\n", argv[1]);
		return 1;
	}
	if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { perror("shutdownd: bind"); return 1; }
	if (listen(s, 8) < 0) { perror("shutdownd: listen"); return 1; }

	if (fork() > 0) return 0;
	setsid();

	for (;;) {
		struct sockaddr_in peer;
		socklen_t plen = sizeof peer;
		int c = accept(s, (struct sockaddr *)&peer, &plen);
		if (c < 0) continue;

		int fired = 0;
		struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
		setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

		/* Read the whole head before answering; replying early and closing
		 * sends an RST that the peer sees as a failed write, not a response. */
		char req[4096];
		size_t got = 0;
		for (;;) {
			if (got >= sizeof req - 1) break;
			ssize_t n = recv(c, req + got, sizeof req - 1 - got, 0);
			if (n <= 0) break;
			got += (size_t)n;
			req[got] = '\0';
			if (strstr(req, "\r\n\r\n") || strstr(req, "\n\n")) break;
		}
		req[got] = '\0';

		if (got == 0) {
			/* nothing to do */
		} else if (strncmp(req, "GET /ping", 9) == 0) {
			say(c, "200 OK", "{\"status\":\"ok\",\"service\":\"shutdownd\"}");
		} else if (strncmp(req, "POST /shutdown", 14) == 0) {
			if (!token_ok(req)) {
				say(c, "403 Forbidden", "{\"error\":\"bad or missing token\"}");
			} else {
				say(c, "200 OK", "{\"status\":\"shutting down\"}");
				fired = 1;
			}
		} else if (strncmp(req, "GET /shutdown", 13) == 0) {
			say(c, "405 Method Not Allowed", "{\"error\":\"use POST\"}");
		} else {
			say(c, "404 Not Found", "{\"error\":\"not found\"}");
		}

		shutdown(c, SHUT_WR);
		for (;;) { char sink[256]; if (recv(c, sink, sizeof sink, 0) <= 0) break; }
		close(c);

		if (fired) {
			/* Flush the response out of the socket buffer before init tears
			 * networking down, then hand off to the normal shutdown path so
			 * rc scripts run and filesystems unmount cleanly. */
			sleep(1);
			sync();
			execl("/sbin/poweroff", "poweroff", (char *)NULL);
			execl("/bin/busybox", "busybox", "poweroff", (char *)NULL);
			/* Last resort if neither exists: ask the kernel directly. */
			reboot(RB_POWER_OFF);
			_exit(1);
		}
	}
}
