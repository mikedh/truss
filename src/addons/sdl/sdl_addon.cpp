#include "sdl_addon.h"
#include <algorithm>
#include <iostream>
#include <sstream>

// windows has apparently deprecated fopen so let's ignore that
#ifdef _WIN32
#pragma warning (disable : 4996)
#endif

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

bool sdlSetWindow(SDL_Window* window_)
{
	SDL_SysWMinfo wmi;
	SDL_VERSION(&wmi.version);
	if (!SDL_GetWindowWMInfo(window_, &wmi))
	{
		return false;
	}

	bgfx_platform_data pd;
#	if BX_PLATFORM_LINUX || BX_PLATFORM_FREEBSD
	pd.ndt          = wmi.info.x11.display;
	pd.nwh          = (void*)(uintptr_t)wmi.info.x11.window;
	pd.context      = NULL;
	pd.backBuffer   = NULL;
	pd.backBufferDS = NULL;
#	elif BX_PLATFORM_OSX
	pd.ndt          = NULL;
	pd.nwh          = wmi.info.cocoa.window;
	pd.context      = NULL;
	pd.backBuffer   = NULL;
	pd.backBufferDS = NULL;
#	elif BX_PLATFORM_WINDOWS
	pd.ndt          = NULL;
	pd.nwh          = wmi.info.win.window;
	pd.context      = NULL;
	pd.backBuffer   = NULL;
	pd.backBufferDS = NULL;
#	endif // BX_PLATFORM_
	bgfx_set_platform_data(&pd);

	return true;
}

SDLAddon::SDLAddon() {
	window_ = NULL;
	owner_ = NULL;
	name_ = "sdl";
	version_ = "0.0.1";
	header_ = R"(
		/* SDL Addon Embedded Header */

		#define TRUSS_SDL_EVENT_OUTOFBOUNDS 0
		#define TRUSS_SDL_EVENT_KEYDOWN     1
		#define TRUSS_SDL_EVENT_KEYUP       2
		#define TRUSS_SDL_EVENT_MOUSEDOWN   3
		#define TRUSS_SDL_EVENT_MOUSEUP     4
		#define TRUSS_SDL_EVENT_MOUSEMOVE   5
		#define TRUSS_SDL_EVENT_MOUSEWHEEL  6
		#define TRUSS_SDL_EVENT_WINDOW      7
		#define TRUSS_SDL_EVENT_TEXTINPUT   8

		typedef struct Addon Addon;
		typedef struct bgfx_callback_interface bgfx_callback_interface_t;

		typedef struct {
		    unsigned int event_type;
		    char keycode[16];
		    double x;
		    double y;
		    double dx;
		    double dy;
		    int flags;
		} truss_sdl_event;

		void truss_sdl_create_window(Addon* addon, int width, int height, const char* name);
		void truss_sdl_destroy_window(Addon* addon);
		int  truss_sdl_num_events(Addon* addon);
		truss_sdl_event truss_sdl_get_event(Addon* addon, int index);
		void truss_sdl_start_textinput(Addon* addon);
		void truss_sdl_stop_textinput(Addon* addon);
		void truss_sdl_set_clipboard(Addon* addon, const char* data);
		const char* truss_sdl_get_clipboard(Addon* addon);
		bgfx_callback_interface_t* truss_sdl_get_bgfx_cb(Addon* addon);
		void truss_sdl_set_relative_mouse_mode(Addon* addon, int mod);
	)";
	errorEvent_.event_type = TRUSS_SDL_EVENT_OUTOFBOUNDS;
}

const std::string& SDLAddon::getName() {
	return name_;
}

const std::string& SDLAddon::getHeader() {
	return header_;
}

const std::string& SDLAddon::getVersion() {
	return version_;
}

void SDLAddon::init(truss::Interpreter* owner) {
	owner_ = owner;

	// Init SDL
	std::cout << "Going to create window; if you get an LLVM crash on linux" <<
		" at this point, the mostly likely reason is that you are using" <<
		" the mesa software renderer.\n";
	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		std::cout << "SDL_Init Error: " << SDL_GetError() << std::endl;
	}
}

void SDLAddon::shutdown() {
	destroyWindow();
	SDL_Quit();
}

void copyKeyName(truss_sdl_event& newEvent, SDL_Event& event) {
	const char* keyname = SDL_GetKeyName(event.key.keysym.sym);
	size_t namelength = std::min<size_t>(TRUSS_SDL_MAX_KEYCODE_LENGTH, strlen(keyname));
	memcpy(newEvent.keycode, keyname, namelength);
	newEvent.keycode[namelength] = '\0'; // zero terminate
}

// hand-written strncpy to get around strncpy being unsafe on
// windows and strncpy_s not existing on linux
//
// as a bonus this will actually null terminate the string
void hackCStrCpy(char* dest, char* src, size_t destsize) {
	bool reachedSrcEnd = false;
	// reserve one byte in dest for null terminator
	for (size_t i = 0; i < destsize-1; ++i) {
		if (reachedSrcEnd) {
			dest[i] = '\0';
		} else {
			dest[i] = src[i];
			reachedSrcEnd = (src[i] == '\0');
		}
	}
	dest[destsize - 1] = '\0';
}

void SDLAddon::convertAndPushEvent_(SDL_Event& event) {
	truss_sdl_event newEvent;
	switch(event.type) {
	case SDL_KEYDOWN:
	case SDL_KEYUP:
		newEvent.event_type = (event.type == SDL_KEYDOWN ?
								TRUSS_SDL_EVENT_KEYDOWN : TRUSS_SDL_EVENT_KEYUP);
		newEvent.flags = event.key.keysym.mod;
		newEvent.x = event.key.keysym.scancode;
		newEvent.y = event.key.keysym.sym;
		copyKeyName(newEvent, event);
		break;
	case SDL_TEXTINPUT:
		newEvent.event_type = TRUSS_SDL_EVENT_TEXTINPUT;
		hackCStrCpy(newEvent.keycode, event.text.text, TRUSS_SDL_KEYCODE_BUFF_SIZE);
		break;
	case SDL_MOUSEMOTION:
		newEvent.event_type = TRUSS_SDL_EVENT_MOUSEMOVE;
		newEvent.x = event.motion.x;
		newEvent.y = event.motion.y;
		newEvent.dx = event.motion.xrel;
		newEvent.dy = event.motion.yrel;
		newEvent.flags = event.motion.state;
		break;
	case SDL_MOUSEBUTTONDOWN:
	case SDL_MOUSEBUTTONUP:
		newEvent.event_type = (event.type == SDL_MOUSEBUTTONDOWN ? 
								TRUSS_SDL_EVENT_MOUSEDOWN : TRUSS_SDL_EVENT_MOUSEUP);
		newEvent.x = event.button.x;
		newEvent.y = event.button.y;
		newEvent.flags = event.button.button;
		break;
	case SDL_MOUSEWHEEL:
		newEvent.event_type = TRUSS_SDL_EVENT_MOUSEWHEEL;
		newEvent.x = event.wheel.x;
		newEvent.y = event.wheel.y;
		newEvent.flags = event.wheel.which;
		break;
	case SDL_WINDOWEVENT:
		newEvent.event_type = TRUSS_SDL_EVENT_WINDOW;
		newEvent.flags = event.window.event;
		break;
	default:
		break;
	}
	eventBuffer_.push_back(newEvent);
}

void SDLAddon::update(double dt) {
	if (window_ == NULL) {
		return;
	}

	eventBuffer_.clear();

	// empty SDL event buffer by polling
	// until none left
	while (SDL_PollEvent(&event_)) {
		convertAndPushEvent_(event_);
	}
}

void SDLAddon::createWindow(int width, int height, const char* name) {
	window_ = SDL_CreateWindow(name
			, SDL_WINDOWPOS_UNDEFINED
			, SDL_WINDOWPOS_UNDEFINED
			, width
			, height
			, SDL_WINDOW_SHOWN
			| SDL_WINDOW_RESIZABLE
			);
	registerBGFX();
}

void SDLAddon::registerBGFX() {
	sdlSetWindow(window_);
}

void SDLAddon::destroyWindow() {
	std::cout << "SDLAddon::destroyWindow not implemented yet.\n";
}

const char* SDLAddon::getClipboardText() {
	char* temp = SDL_GetClipboardText();
	clipboard_ = temp;
	SDL_free(temp);
	return clipboard_.c_str();
}

SDLAddon::~SDLAddon() {
	shutdown();
}

int SDLAddon::numEvents() {
	return (int)(eventBuffer_.size());
}

truss_sdl_event& SDLAddon::getEvent(int index) {
	if (index >= 0 && index < eventBuffer_.size()) {
		return eventBuffer_[index];
	}
	else {
		return errorEvent_;
	}
}

void truss_sdl_create_window(SDLAddon* addon, int width, int height, const char* name) {
	addon->createWindow(width, height, name);
}

void truss_sdl_destroy_window(SDLAddon* addon) {
	addon->destroyWindow();
}

int  truss_sdl_num_events(SDLAddon* addon) {
	return addon->numEvents();
}

truss_sdl_event truss_sdl_get_event(SDLAddon* addon, int index) {
	return addon->getEvent(index);
}

void truss_sdl_start_textinput(SDLAddon* addon) {
	SDL_StartTextInput();
}

void truss_sdl_stop_textinput(SDLAddon* addon) {
	SDL_StopTextInput();
}

void truss_sdl_set_clipboard(SDLAddon* addon, const char* data) {
	SDL_SetClipboardText(data);
}

const char* truss_sdl_get_clipboard(SDLAddon* addon) {
	return addon->getClipboardText();
}

void truss_sdl_set_relative_mouse_mode(SDLAddon* addon, int mode) {
	if (mode > 0) {
		SDL_SetRelativeMouseMode(SDL_TRUE);
	} else {
		SDL_SetRelativeMouseMode(SDL_FALSE);
	}
}

void bgfx_cb_fatal(bgfx_callback_interface_t* _this, bgfx_fatal_t _code, const char* _str) {
	std::stringstream ss;
	ss << "Fatal BGFX Error, code [" << _code << "]: " << _str;
	truss_log(TRUSS_LOG_CRITICAL, ss.str().c_str());
}

void bgfx_cb_trace_vargs(bgfx_callback_interface_t* _this, const char* _filePath, uint16_t _line, const char* _format, va_list _argList) {
	// oh boy what is this supposed to do?
	truss_log(TRUSS_LOG_CRITICAL, "I have no clue what the trace_vargs callback is supposed to do??");
}

uint32_t bgfx_cb_cache_read_size(bgfx_callback_interface_t* _this, uint64_t _id) {
	truss_log(TRUSS_LOG_WARNING, "bgfx_cb_cache_read_size not implemented.");
	return 0;
}

bool bgfx_cb_cache_read(bgfx_callback_interface_t* _this, uint64_t _id, void* _data, uint32_t _size) {
	truss_log(TRUSS_LOG_WARNING, "bgfx_cb_cache_read not implemented.");
	return false;
}

void bgfx_cb_cache_write(bgfx_callback_interface_t* _this, uint64_t _id, const void* _data, uint32_t _size) {
	truss_log(TRUSS_LOG_WARNING, "bgfx_cb_cache_write not implemented.");
	// nothing to do
}

void bgfx_cb_screen_shot(bgfx_callback_interface_t* _this, const char* _filePath, uint32_t _width, uint32_t _height, uint32_t _pitch, const void* _data, uint32_t _size, bool _yflip) {
	truss_log(TRUSS_LOG_WARNING, "bgfx_cb_screen_shot implemented with direct writes to file!");
	truss_log(TRUSS_LOG_INFO, _filePath);
	std::stringstream ss;
	ss << "w: " << _width << ", h: " << _height << ", p: " << _pitch << ", s: " << _size << ", yf: " << _yflip;
	truss_log(TRUSS_LOG_INFO, ss.str().c_str());
	char* temp = new char[_size];
	bgfx_image_swizzle_bgra8(_width, _height, _pitch, _data, temp);
	stbi_write_png(_filePath, _width, _height, 4, temp, _pitch);
	delete[] temp;
}

void bgfx_cb_capture_begin(bgfx_callback_interface_t* _this, uint32_t _width, uint32_t _height, uint32_t _pitch, bgfx_texture_format_t _format, bool _yflip) {
	truss_log(TRUSS_LOG_WARNING, "bgfx_cb_capture_begin not implemented.");
}

void bgfx_cb_capture_end(bgfx_callback_interface_t* _this) {
	truss_log(TRUSS_LOG_WARNING, "bgfx_cb_capture_end not implemented.");
}

void bgfx_cb_capture_frame(bgfx_callback_interface_t* _this, const void* _data, uint32_t _size) {
	// todo
}

static const bgfx_callback_vtbl sdl_vtbl = {
	bgfx_cb_fatal,
	bgfx_cb_trace_vargs,
	bgfx_cb_cache_read_size,
	bgfx_cb_cache_read,
	bgfx_cb_cache_write,
	bgfx_cb_screen_shot,
	bgfx_cb_capture_begin,
	bgfx_cb_capture_end,
	bgfx_cb_capture_frame
};

static bgfx_callback_interface_t sdl_cb_struct = {
	&sdl_vtbl
};

bgfx_callback_interface_t* truss_sdl_get_bgfx_cb(SDLAddon* addon) {
	return &sdl_cb_struct;
}
