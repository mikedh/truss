// C++ truss implementation

// TODO: switch to a better logging framework
#include <iostream>
#include <fstream>
#include "trussapi.h"
#include "truss.h"
#include "terra.h"

using namespace trss;

Interpreter::Interpreter(int id, const char* name) {
		_thread = NULL;
		_messageLock = SDL_CreateMutex();
		_execLock = SDL_CreateMutex();
		_terraState = NULL;
		_running = false;
		_autoExecute = true;
		_executeOnMessage = false;
		_executeNext = false;
		_name = name;
		_ID = id;
		_curMessages = new std::vector < trss_message* > ;
		_fetchedMessages = new std::vector < trss_message* >;
		_arg = "";
}

Interpreter::~Interpreter() {
	// Nothing special to do
}

const std::string& Interpreter::getName() const {
	return _name;
}

int Interpreter::getID() const {
	return _ID;
}

void Interpreter::attachAddon(Addon* addon) {
	if(!_running && _thread == NULL) {
		_addons.push_back(addon);
	} else {
		std::cout << "Cannot attach addon to running interpreter.\n";
		delete addon;
	}
}

int Interpreter::numAddons() {
	return (int)(_addons.size());
}

Addon* Interpreter::getAddon(int idx) {
	if(idx >= 0 && idx < _addons.size()) {
		return _addons[idx];
	} else {
		return NULL;
	}
}

int run_interpreter_thread(void* interpreter) {
	Interpreter* target = (Interpreter*)interpreter;
	target->_threadEntry();
	return 0;
}

void Interpreter::start(const char* arg) {
	if(_thread != NULL || _running) {
		std::cout << "Can't start interpreter twice: already running\n"; 
		return;
	}

	_arg = arg;
	_running = true;
	_thread = SDL_CreateThread(run_interpreter_thread, 
								_name.c_str(), 
								(void*)this);
}

void Interpreter::startUnthreaded(const char* arg) {
	if(_thread != NULL || _running) {
		std::cout << "Can't start interpreter twice: already running\n"; 
		return;
	}

	_arg = arg;
	_running = true;
	_threadEntry();
}

void Interpreter::stop() {
	_running = false;
}

void Interpreter::execute() {
	std::cout << "Interpreter::execute not implemented!\n";
	// TODO: make this do something
}

void Interpreter::_threadEntry() {
	_terraState = luaL_newstate();
	luaL_openlibs(_terraState);
	terra_Options* opts = new terra_Options;
	opts->verbose = 2; // very verbose
	opts->debug = 1; // debug enabled
	terra_initwithoptions(_terraState, opts);
	delete opts; // not sure if necessary or desireable

	// load and execute the bootstrap script
	trss_message* bootstrap = trss_load_file("bootstrap.t", TRSS_CORE_PATH);
	if (!bootstrap) {
		std::cout << "Error loading bootstrap script.\n";
		_running = false;
		return;
	}
	terra_loadbuffer(_terraState, 
                     (char*)bootstrap->data, 
                     bootstrap->data_length, 
                     "bootstrap.t");
	int res = lua_pcall(_terraState, 0, 0, 0);
	if(res != 0) {
		std::cout << "Error bootstrapping interpreter: " 
				  << lua_tostring(_terraState, -1) << std::endl;
		_running = false;
		return;
	}

	// Init all the addons
	for(size_t i = 0; i < _addons.size(); ++i) {
		_addons[i]->init(this);
	}

	// Call init
	_safeLuaCall("_coreInit", _arg.c_str());

	double dt = 1.0 / 60.0; // just fudge this at the moment

	// Enter thread main loop
	while(_running) {
		// update addons
		for(unsigned int i = 0; i < _addons.size(); ++i) {
			_addons[i]->update(dt);
		}

		// update lua
		_safeLuaCall("_coreUpdate");
	}

	// Shutdown
	std::cout << "Shutting down.\n";
	// TODO: actually shutdown stuff here
}

void Interpreter::sendMessage(trss_message* message) {
	SDL_LockMutex(_messageLock);
	trss_acquire_message(message);
	_curMessages->push_back(message);
	SDL_UnlockMutex(_messageLock);
}

int Interpreter::fetchMessages() {
	SDL_LockMutex(_messageLock);
	// swap messages
	std::vector<trss_message*>* temp = _curMessages;
	_curMessages = _fetchedMessages;
	_fetchedMessages = temp;

	// clear the 'current' messages (i.e., the old fetched messages)
	for(unsigned int i = 0; i < _curMessages->size(); ++i) {
		trss_release_message((*_curMessages)[i]);
	}
	_curMessages->clear();
	size_t numMessages = _fetchedMessages->size();

	SDL_UnlockMutex(_messageLock);
	return (int)(numMessages);
}

trss_message* Interpreter::getMessage(int index) {
	// Note: don't need to lock because only 'our' thread
	// should call fetchMessages (which is the only other function
	// that touches _fetchedMessages)
	return (*_fetchedMessages)[index];
}

void Interpreter::_safeLuaCall(const char* funcname, const char* argstr) {
	int nargs = 0;
	lua_getglobal(_terraState, funcname);
	if(argstr != NULL) {
		nargs = 1;
		lua_pushstring(_terraState, argstr);	
	}
	int res = lua_pcall(_terraState, nargs, 0, 0);
	if(res != 0) {
		std::cout << lua_tostring(_terraState, -1) << std::endl;
	}
}

void trss_test() {
	std::cout << ">>>>>>>>>>>>>> TRSS_TEST CALLED <<<<<<<<<<<<<\n";
}

void trss_log(int log_level, const char* str){
	Core::getCore()->logMessage(log_level, str);
}

trss_message* trss_load_file(const char* filename, int path_type){
	return Core::getCore()->loadFile(filename, path_type);
}

/* Note that when saving the message_type field is not saved */
int trss_save_file(const char* filename, int path_type, trss_message* data){
	Core::getCore()->saveFile(filename, path_type, data);
	return 0; // TODO: actually check for errors
}

/* Interpreter management functions */
int trss_spawn_interpreter(const char* name){
	Interpreter* spawned = Core::getCore()->spawnInterpreter(name);
	return spawned->getID();
}

void trss_start_interpreter(trss_interpreter_id target_id, const char* msgstr) {
	Core::getCore()->getInterpreter(target_id)->start(msgstr);
}

void trss_stop_interpreter(trss_interpreter_id target_id){
	Core::getCore()->getInterpreter(target_id)->stop();
}

void trss_execute_interpreter(trss_interpreter_id target_id){
	return Core::getCore()->getInterpreter(target_id)->execute();
}

int trss_find_interpreter(const char* name){
	return Core::getCore()->getNamedInterpreter(name)->getID();
}

void trss_send_message(trss_interpreter_id dest, trss_message* message){
	Core::getCore()->dispatchMessage(dest, message);
}

int trss_fetch_messages(trss_interpreter_id idx){
	Interpreter* interpreter = Core::getCore()->getInterpreter(idx);
	if(interpreter) {
		return interpreter->fetchMessages();
	} else {
		return -1;
	}
}

trss_message* trss_get_message(trss_interpreter_id idx, int message_index){
	Interpreter* interpreter = Core::getCore()->getInterpreter(idx);
	if(interpreter) {
		return interpreter->getMessage(message_index);
	} else {
		return NULL;
	}
}

int trss_get_addon_count(trss_interpreter_id target_id) {
	Interpreter* interpreter = Core::getCore()->getInterpreter(target_id);
	if(interpreter) {
		return interpreter->numAddons();
	} else {
		return -1;
	}
}

Addon* trss_get_addon(trss_interpreter_id target_id, int addon_idx) {
	Interpreter* interpreter = Core::getCore()->getInterpreter(target_id);
	if(interpreter) {
		return interpreter->getAddon(addon_idx);
	} else {
		return NULL;
	}
}

const char* trss_get_addon_name(trss_interpreter_id target_id, int addon_idx) {
	Addon* addon = trss_get_addon(target_id, addon_idx);
	if (addon) {
		return addon->getName().c_str();
	}
	else {
		return "";
	}
}

const char* trss_get_addon_header(trss_interpreter_id target_id, int addon_idx) {
	Addon* addon = trss_get_addon(target_id, addon_idx);
	if(addon) {
		return addon->getCHeader().c_str();
	} else {
		return "";
	}
}

/* Message management functions */
trss_message* trss_create_message(unsigned int data_length){
	return Core::getCore()->allocateMessage(data_length);
}

void trss_acquire_message(trss_message* msg){
	++(msg->_refcount);
}

void trss_release_message(trss_message* msg){
	--(msg->_refcount);
	if(msg->_refcount <= 0) {
		Core::getCore()->deallocateMessage(msg);
	}
}

trss_message* trss_copy_message(trss_message* src){
	trss_message* newmsg = Core::getCore()->allocateMessage(src->data_length);
	newmsg->message_type = src->message_type;
	memcpy(newmsg->data, src->data, newmsg->data_length);
	return newmsg;
}

Core* Core::__core = NULL;

Core* Core::getCore() {
	if(__core == NULL) {
		__core = new Core();
	}
	return __core;
}

void Core::logMessage(int log_level, const char* msg) {
	SDL_LockMutex(_coreLock);
	// just dump to standard out for the moment
	std::cout << log_level << "|" << msg << std::endl;
	SDL_UnlockMutex(_coreLock);
}

Interpreter* Core::getInterpreter(int idx){
	Interpreter* ret = NULL;
	SDL_LockMutex(_coreLock);
	if(idx >= 0 && idx < _interpreters.size()) {
		ret = _interpreters[idx];
	}
	SDL_UnlockMutex(_coreLock);
	return ret;
}

Interpreter* Core::getNamedInterpreter(const char* name){
	std::string sname(name);
	Interpreter* ret = NULL;
	SDL_LockMutex(_coreLock);
	for(size_t i = 0; i < _interpreters.size(); ++i) {
		if(_interpreters[i]->getName() == sname) {
			ret = _interpreters[i];
			break;
		}
	}
	SDL_UnlockMutex(_coreLock);
	return ret;
}

Interpreter* Core::spawnInterpreter(const char* name){
	SDL_LockMutex(_coreLock);
	Interpreter* interpreter = new Interpreter((int)(_interpreters.size()), name);
	_interpreters.push_back(interpreter);
	SDL_UnlockMutex(_coreLock);
	return interpreter;
}

int Core::numInterpreters(){
	int ret = 0;
	SDL_LockMutex(_coreLock);
	ret = (int)(_interpreters.size());
	SDL_UnlockMutex(_coreLock);
	return ret;
}

void Core::dispatchMessage(int targetIdx, trss_message* msg){
	Interpreter* interpreter = getInterpreter(targetIdx);
	if(interpreter) {
		interpreter->sendMessage(msg);
	}
}

void Core::acquireMessage(trss_message* msg){
	SDL_LockMutex(_coreLock);
	++(msg->_refcount);
	SDL_UnlockMutex(_coreLock);
}

void Core::releaseMessage(trss_message* msg){
	SDL_LockMutex(_coreLock);
	--(msg->_refcount);
	if(msg->_refcount <= 0) {
		deallocateMessage(msg);
	}
	SDL_UnlockMutex(_coreLock);
}

trss_message* Core::copyMessage(trss_message* src){
	SDL_LockMutex(_coreLock);
	trss_message* newmsg = allocateMessage(src->data_length);
	newmsg->message_type = src->message_type;
	memcpy(newmsg->data, src->data, newmsg->data_length);
	SDL_UnlockMutex(_coreLock);
	return newmsg;
}

trss_message* Core::allocateMessage(int dataLength){
	trss_message* ret = new trss_message;
	ret->data = new unsigned char[dataLength];
	ret->data_length = dataLength;
	ret->_refcount = 1;
	return ret;
}

void Core::deallocateMessage(trss_message* msg){
	delete[] msg->data;
	delete msg;
}

std::string Core::_resolvePath(const char* filename, int path_type) {
	// just return the filename for now
	std::string ret(filename);
	return ret;
}

trss_message* Core::loadFile(const char* filename, int path_type) {
	std::string truepath = _resolvePath(filename, path_type);

	std::streampos size;
	std::ifstream file(truepath.c_str(), std::ios::in|std::ios::binary|std::ios::ate);
	if (file.is_open())
	{
		size = file.tellg();
		trss_message* ret = allocateMessage((int)size);
		file.seekg (0, std::ios::beg);
		file.read ((char*)(ret->data), size);
		file.close();

		return ret;
	} else {
		std::cout << "Unable to open file " << filename << "\n";
		return NULL;	
	} 
}

void Core::saveFile(const char* filename, int path_type, trss_message* data) {
	std::string truepath = _resolvePath(filename, path_type);

	std::ofstream outfile;
	outfile.open(truepath.c_str(), std::ios::binary | std::ios::out);
	outfile.write((char*)(data->data), data->data_length);
	outfile.close();
}

Core::~Core(){
	// eeeehn
}

Core::Core(){
	_coreLock = SDL_CreateMutex();
}
