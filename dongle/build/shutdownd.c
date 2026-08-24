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
 * It also polls the phone. Android will not let an app bind a socket to this
 * AP (no NET_CAPABILITY_INTERNET, so requestNetwork is never satisfied and
 * bindSocket fails EPERM), which makes phone -> dongle impossible. dongle ->
 * phone is the direction that already works, so the dongle asks the app whether
 * it should power off rather than waiting to be told.
 *
 * usage: shutdownd <bind-ip> <port> [token] [poll-ip poll-port poll-interval]
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

static void do_poweroff(void) {
	sync();
	execl("/sbin/poweroff", "poweroff", (char *)NULL);
	execl("/bin/busybox", "busybox", "poweroff", (char *)NULL);
	reboot(RB_POWER_OFF);
	_exit(1);
}

/* One poll: GET the phone's poll path and look for a true shutdown flag.
 * Returns 1 if the app asked us to power off. */
static int poll_once(const char *ip, int port) {
	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0) return 0;

	struct timeval tv = { .tv_sec = 8, .tv_usec = 0 };
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((unsigned short)port);
	if (inet_pton(AF_INET, ip, &a.sin_addr) != 1 ||
	    connect(s, (struct sockaddr *)&a, sizeof a) < 0) {
		close(s);
		return 0;                      /* app not running yet; try again later */
	}

	char req[256];
	int n = snprintf(req, sizeof req,
		"GET /__aawg/poll HTTP/1.1\r\nHost: %s:%d\r\n"
		"Connection: close\r\nUser-Agent: aawg-shutdownd\r\n\r\n", ip, port);
	if (send(s, req, (size_t)n, 0) != n) { close(s); return 0; }

	char buf[2048];
	size_t got = 0;
	for (;;) {
		if (got >= sizeof buf - 1) break;
		ssize_t r = recv(s, buf + got, sizeof buf - 1 - got, 0);
		if (r <= 0) break;
		got += (size_t)r;
	}
	close(s);
	buf[got] = '\0';

	/* Only act on a 200; an error page must never power the car link down. */
	if (strncmp(buf, "HTTP/1.1 200", 12) != 0 && strncmp(buf, "HTTP/1.0 200", 12) != 0)
		return 0;
	const char *body = strstr(buf, "\r\n\r\n");
	if (!body) return 0;
	return strstr(body, "\"shutdown\":true") != NULL;
}

static void poll_loop(const char *ip, int port, int interval) {
	for (;;) {
		if (poll_once(ip, port)) do_poweroff();
		sleep((unsigned)interval);
	}
}

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
	if (argc < 3 || (argc > 4 && argc != 7)) {
		fprintf(stderr,
			"usage: %s <bind-ip> <port> [token] [poll-ip poll-port poll-interval]\n",
			argv[0]);
		return 2;
	}
	if (argc >= 4 && *argv[3]) token = argv[3];

	const char *poll_ip = NULL;
	int poll_port = 0, poll_interval = 15;
	if (argc == 7 && *argv[4]) {
		poll_ip = argv[4];
		poll_port = atoi(argv[5]);
		poll_interval = atoi(argv[6]);
		if (poll_interval < 5) poll_interval = 5;
	}
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

	/* Poller runs in its own process so a blocked poll cannot stall the
	 * listener, and vice versa. */
	if (poll_ip) {
		pid_t p = fork();
		if (p == 0) {
			close(s);
			poll_loop(poll_ip, poll_port, poll_interval);
			_exit(0);
		}
	}

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
			do_poweroff();
		}
	}
}
