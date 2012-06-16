module zbasud;

import std.algorithm: startsWith, map;
import std.array: join;
import std.datetime: SysTime;
import std.exception: enforce;
import std.file: chdir, read, write, readText, exists, timeLastModified;
import std.path: dirSeparator, extension, stripExtension, setExtension;
import std.process: environment, shell;
import std.stdio: writeln;
import std.typecons: Tuple, tuple;

import ctpg;
import msgpack: pack, unpack;

enum projectFileName = ".vimprojects";
enum dataFileName = ".zbasud.msgpack";

struct Parsers{
    mixin(generateParsers(q{
        Data root = ss project*<ss> ss $ | makeAA | Data;

        Tuple!(string, Project) project = ((^"=" any)+ | join) !"=" (((^" " any)+ | join) !" {\n" ss imports ss libs ss sourceFile*<ss> ss !"}" | Project);

        string[] imports = !"#imports" sss ( (^"," ^"\n" any)+ | join)*<sss "," sss> sss !"\n";

        string[] libs = !"#libs" sss ((^"," ^"\n" any)+ >> join)*<sss "," sss> sss !"\n";

        SourceFile sourceFile = (^"}" ^"\n" any)+ !"\n" | join | SourceFile;

        None sss = !((^"\n" parseSpace)*);
    }));

    unittest{
        {
            auto r = parse!sourceFile("src/zbasud.d\n");
            assert(r.path == "src/zbasud.d");
        }
        {
            auto r = parse!imports("#imports src, ctpg/src,msgpack-d/src\n");
            assert(r == ["src", "ctpg/src", "msgpack-d/src"]);
        }
        {
            auto r = parse!libs("#libs ctpg/ctpg.lib, msgpack-d/msgpack.lib\n");
            assert(r == ["ctpg/ctpg.lib", "msgpack-d/msgpack.lib"]);
        }
        {
            auto r = parse!project(
                `zbasud=~/zbasud {
                    #imports src,ctpg/src,msgpack-d/src
                    #libs ctpg/ctpg.lib,msgpack-d/msgpack.lib
                    src/zbasud.d
                }`
            );
            assert(r[0] == "zbasud");
            assert(r[1].path == "~/zbasud");
            assert(r[1].imports == ["src", "ctpg/src", "msgpack-d/src"]);
            assert(r[1].libs == ["ctpg/ctpg.lib", "msgpack-d/msgpack.lib"]);
            assert(r[1].files[0].path == "src/zbasud.d");
        }
        {
            Data r = parse!root(`
                ctpg=~/ctpg {
                    #imports src
                    #libs
                    src/ctpg.d
                }

                ciprad=~/ciprad {
                    #imports src
                    #libs
                    src/ciprad.d
                }

                zbasud=~/zbasud {
                    #imports src, ctpg/src, msgpack-d/src
                    #libs ctpg/ctpg.lib, msgpack-d/msgpack.lib
                    src/zbasud.d
                }
            `);
            assert(r.projects.length == 3);
            assert(r.projects["ctpg"].path == "~/ctpg");
            assert(r.projects["ctpg"].imports == ["src"]);
            assert(r.projects["ctpg"].libs.length == 0);
            assert(r.projects["ctpg"].files.length == 1);
            assert(r.projects["ctpg"].files[0].path == "src/ctpg.d");
            assert(r.projects["ciprad"].path == "~/ciprad");
            assert(r.projects["ciprad"].imports == ["src"]);
            assert(r.projects["ciprad"].libs.length == 0);
            assert(r.projects["ciprad"].files.length == 1);
            assert(r.projects["ciprad"].files[0].path == "src/ciprad.d");
            assert(r.projects["zbasud"].path == "~/zbasud");
            assert(r.projects["zbasud"].imports == ["src", "ctpg/src", "msgpack-d/src"]);
            assert(r.projects["zbasud"].libs == ["ctpg/ctpg.lib", "msgpack-d/msgpack.lib"]);
            assert(r.projects["zbasud"].files.length == 1);
            assert(r.projects["zbasud"].files[0].path == "src/zbasud.d");
        }
    }
}

struct Data{
    Project[string] projects;
    long modified;
}

struct Project{
    string path;
    string[] imports;
    string[] libs;
    SourceFile[] files;
}

struct SourceFile{
    string path;
    long modified;
    string objPath;
}

Value[Key] makeAA(Key, Value)(Tuple!(Key, Value)[] tuples){
    typeof(return) aa;
    foreach(tuple; tuples){
        aa[tuple[0]] = tuple[1];
    }
    return aa;
}

void main(string[] args){
    enforce(args.length == 2, "too few arguments");
    immutable string target = args[1];

    version(Windows){
        immutable string prefix = environment["USERPROFILE"];
        immutable string objExt = "obj";
    }else version(Posix){
        immutable string prefix = environment["HOME"];
        immutable string objExt = "o";
    }else{
        static assert(false);
    }

    immutable string projectFile = prefix ~ dirSeparator ~ projectFileName;
    immutable string dataFile = prefix ~ dirSeparator ~ dataFileName;
    projectFile.exists().enforce(projectFile ~ " not found");

    Data data;

    if(dataFile.exists()){
        unpack(cast(ubyte[])dataFile.read(), data);
        "DataFileLoadedFromFile".writeln();
    }

    immutable long modified = projectFile.timeLastModified().stdTime;
    bool recreated;
    if(modified > data.modified){
        recreated = true;
        "DataFileRecreated".writeln();
        data = projectFile.readText().parse!(Parsers.root)();
        data.modified = modified;
        foreach(ref project; data.projects.byValue()){
            if(project.path.startsWith('~')){
                project.path = prefix ~ project.path[1..$];
            }
            foreach(ref file; project.files){
                file.modified = (project.path ~ dirSeparator ~ file.path).timeLastModified().stdTime;
                file.objPath = "obj" ~ dirSeparator ~ file.path.stripExtension().setExtension(objExt);
            }
        }
        dataFile.write(pack(data));
    }

    Project project = data.projects[target];
    immutable string imports = project.imports.map!q{"-I" ~ a ~ " "}().join();
    chdir(project.path);

    foreach(file; project.files){
        if(file.path.extension() == ".d" && (!file.objPath.exists() || recreated || file.modified < file.path.timeLastModified().stdTime)){
            shell("dmd -c -op -odobj " ~ imports ~ file.path);
            writeln("compiled ", file.path);
        }
    }
}

