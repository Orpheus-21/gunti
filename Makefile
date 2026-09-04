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

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(NAME)
	rm -rf $(DESTDIR)$(PREFIX)/share/licenses/$(NAME)

clean:
	rm -f $(NAME) $(NAME).sha256

.PHONY: all release test install uninstall clean
