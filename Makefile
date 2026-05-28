BINARY      = PreClickFocus
APP_BUNDLE  = PreClickFocus.app
APP_BINARY  = $(APP_BUNDLE)/Contents/MacOS/$(BINARY)
SRC         = PreClickFocus.mm
CXX         = clang++
CXXFLAGS    = -ObjC++ -fobjc-arc \
              -framework Cocoa \
              -framework ApplicationServices \
              -framework Carbon \
              -framework ServiceManagement \
              -mmacosx-version-min=12.0 \
              -o $(BINARY)
CODE_SIGN_IDENTITY =

.PHONY: all app clean install

all: app

$(BINARY): $(SRC) Info.plist
	$(CXX) $(CXXFLAGS) $(SRC)

app: $(BINARY)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp $(BINARY) $(APP_BINARY)
	codesign --force --deep --sign - $(APP_BUNDLE)

clean:
	rm -f $(BINARY)
	rm -f $(APP_BINARY)

install: $(BINARY)
	cp $(BINARY) /usr/local/bin/$(BINARY)
