BINARY      = PreClickFocus
SRC         = PreClickFocus.mm
CXX         = clang++
CXXFLAGS    = -ObjC++ -fobjc-arc \
              -framework Cocoa \
              -framework ApplicationServices \
              -framework Carbon \
              -mmacosx-version-min=12.0 \
              -o $(BINARY)
CODE_SIGN_IDENTITY =

.PHONY: all clean install

all: $(BINARY)

$(BINARY): $(SRC) Info.plist
	$(CXX) $(CXXFLAGS) $(SRC)

clean:
	rm -f $(BINARY)

install: $(BINARY)
	cp $(BINARY) /usr/local/bin/$(BINARY)
