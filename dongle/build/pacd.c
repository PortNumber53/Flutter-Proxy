/*
 * pacd -- a ~100 line static HTTP server whose only job is to hand out one PAC
 * file with the right MIME type.
 *
 * Fallback for images whose busybox was built without the httpd applet. It
 * answers any GET with the same file and 400s everything else; that is the
 * entire feature set on purpose.
 *
 * usage: pacd <bind-ip> <port> <pac-file>
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
#include <sys/wait.h>

static char body[65536];
static size_t body_len;

static int load(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) return -1;
	body_len = fread(body, 1, sizeof(body) - 1, f);
	fclose(f);
	return 0;
}

int main(int argc, char **argv) {
	if (argc != 4) {
		fprintf(stderr, "usage: %s <bind-ip> <port> <pac-file>\n", argv[0]);
		return 2;
	}
	signal(SIGPIPE, SIG_IGN);
	signal(SIGCHLD, SIG_IGN);

	if (load(argv[3]) < 0) {
		perror("pacd: cannot read pac file");
		return 1;
	}

	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0) { perror("pacd: socket"); return 1; }
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((unsigned short)atoi(argv[2]));
	if (inet_pton(AF_INET, argv[1], &a.sin_addr) != 1) {
		fprintf(stderr, "pacd: bad bind address %s\n", argv[1]);
		return 1;
	}
	if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { perror("pacd: bind"); return 1; }
	if (listen(s, 16) < 0) { perror("pacd: listen"); return 1; }

	/* daemonise so bootstrap.sh's `&` is not the only thing detaching us */
	if (fork() > 0) return 0;
	setsid();

	for (;;) {
		int c = accept(s, NULL, NULL);
		if (c < 0) continue;

		/* One child per connection: a client that opens a socket and stalls
		 * must not be able to block the PAC for every other device on the AP. */
		if (fork() != 0) { close(c); continue; }
		close(s);

		/* Belt and braces on top of the fork -- bound how long a child lives. */
		struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
		setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

		/* Read the WHOLE request head before answering. Replying and closing
		 * while the peer is still writing makes the kernel send an RST, which
		 * the peer sees as a failed write rather than as our response. curl
		 * fits its headers in one segment and never noticed; tinyproxy, which
		 * forwards a larger header block, hit it on every request. */
		char req[4096];
		size_t got = 0;
		for (;;) {
			if (got >= sizeof req - 1) break;          /* oversized: answer anyway */
			ssize_t n = recv(c, req + got, sizeof req - 1 - got, 0);
			if (n <= 0) break;
			got += (size_t)n;
			req[got] = '\0';
			if (strstr(req, "\r\n\r\n") || strstr(req, "\n\n")) break;
		}
		if (got == 0) { close(c); _exit(0); }
		req[got] = '\0';

		char out[1024];
		if (strncmp(req, "GET ", 4) == 0) {
			/* Re-read each time: bootstrap.sh may have re-rendered the file. */
			load(argv[3]);
			int h = snprintf(out, sizeof out,
				"HTTP/1.1 200 OK\r\n"
				"Content-Type: application/x-ns-proxy-autoconfig\r\n"
				"Content-Length: %zu\r\n"
				"Cache-Control: no-cache\r\n"
				"Connection: close\r\n\r\n", body_len);
			send(c, out, (size_t)h, 0);
			send(c, body, body_len, 0);
		} else {
			const char *e = "HTTP/1.1 400 Bad Request\r\n"
			                "Content-Length: 0\r\nConnection: close\r\n\r\n";
			send(c, e, strlen(e), 0);
		}

		/* Half-close, then drain whatever is still in flight so the peer's
		 * final writes land in a buffer instead of provoking an RST. */
		shutdown(c, SHUT_WR);
		for (;;) {
			char sink[512];
			ssize_t n = recv(c, sink, sizeof sink, 0);
			if (n <= 0) break;
		}
		close(c);
		_exit(0);
	}
}
