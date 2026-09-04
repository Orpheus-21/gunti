PREFIX ?= /usr/local
ODIN   ?= odin
NAME   := gunti

all: $(NAME)

$(NAME): main.odin
	$(ODIN) build . -out:$@ -o:speed

# static, so one binary runs on any linux regardless of libc version or flavour.
# gunti touches no name service lookups, so static glibc has nothing to break.
release:
	$(ODIN) build . -out:$(NAME) -o:speed -extra-linker-flags:"-static"
	strip $(NAME)
	sha256sum $(NAME) > $(NAME).sha256

test:
	$(ODIN) test .

install: $(NAME)
	install -Dm755 $(NAME) $(DESTDIR)$(PREFIX)/bin/$(NAME)
	install -Dm644 LICENSE $(DESTDIR)$(PREFIX)/share/licenses/$(NAME)/LICENSE
	install -Dm644 $(NAME).1 $(DESTDIR)$(PREFIX)/share/man/man1/$(NAME).1
	install -Dm644 config.example $(DESTDIR)$(PREFIX)/share/doc/$(NAME)/config.example

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(NAME)
	rm -f $(DESTDIR)$(PREFIX)/share/man/man1/$(NAME).1
	rm -rf $(DESTDIR)$(PREFIX)/share/licenses/$(NAME)
	rm -rf $(DESTDIR)$(PREFIX)/share/doc/$(NAME)

clean:
	rm -f $(NAME) $(NAME).sha256

.PHONY: all release test install uninstall clean
