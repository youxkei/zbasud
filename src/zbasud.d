module zbasud;

import std.file: read, exists;
import std.datetime: SysTime;

import ctpg;
import msgpack: pack, unpack;

mixin(generateParsers(q{
    Tuple!()[]
}));

struct Data{
    Tuple!("file", string, "time", SysTime) files;
}

void main(){
    Data data;
    if(exists("~/.zbasud")){
        unpack(cast(ubyte[])read("~/.zbasud"), data);
    }
}
