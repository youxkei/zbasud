// Written in the D programming language.
module zbasud;

import std.algorithm: startsWith, map, filter;
import std.array:     join, replace;
import std.datetime:  SysTime;
import std.exception: enforce;
import std.file:      chdir, read, write, readText, exists, timeLastModified;
import std.getopt:    getopt;
import std.path:      dirSeparator, extension, stripExtension, setExtension;
import std.process:   environment, system;
import std.stdio:     writeln;
import std.typecons:  Tuple, tuple;

import ctpg;
import msgpack: pack, unpack;

enum projectFileName = ".vimprojects";
enum dataFileName = ".zbasud.msgpack";

struct Parsers
{
    mixin(generateParsers(q{
        @default_skip(defaultSkip)

        Data root = project* $ >> makeAA >> Data;

        Project project = projectName !"=" projectPath !"{\n" imports libs sourceFile* !"}" >> Project;

        string projectName = (^"=" any)+ >> join;

        string projectPath = (^"{" any)+ >> join;

        @default_skip(^"\n" defaultSkip)

        string[] imports = !"#imports" _import*<","> !("\n"+);

        string _import = (^"," ^"\n" any)+ >> join;

        string[] libs = !"#libs" lib*<","> !("\n"+);

        string lib = (^"," ^"\n" any)+ >> join;

        SourceFile sourceFile = (^"}" ^"\n" any)+ >> join >> SourceFile;
    }));

    unittest
    {
        {
            auto r = parse!sourceFile("src/zbasud.d\n");
            assert(r.match);
            assert(r.value.path == "src/zbasud.d");
        }
        {
            auto r = parse!imports("#imports src, ctpg/src,msgpack-d/src\n");
            assert(r.match);
            assert(r.value == ["src", "ctpg/src", "msgpack-d/src"]);
        }
        {
            auto r = parse!libs("#libs ctpg/ctpg.lib, msgpack-d/msgpack.lib\n");
            assert(r.match);
            assert(r.value == ["ctpg/ctpg.lib", "msgpack-d/msgpack.lib"]);
        }
        {
            auto r = parse!project(
                `zbasud=~/zbasud {
                    #imports src,ctpg/src,msgpack-d/src
                    #libs ctpg/ctpg.lib,msgpack-d/msgpack.lib
                    src/zbasud.d
                }`
            );
            assert(r.match);
            assert(r.value.name == "zbasud");
            assert(r.value.path == "~/zbasud");
            assert(r.value.imports == ["src", "ctpg/src", "msgpack-d/src"]);
            assert(r.value.libs == ["ctpg/ctpg.lib", "msgpack-d/msgpack.lib"]);
            assert(r.value.files[0].path == "src/zbasud.d");
        }
        {
            auto r = parse!root(`
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
            assert(r.match);
            assert(r.value.projects.length == 3);
            assert(r.value.projects["ctpg"].path == "~/ctpg");
            assert(r.value.projects["ctpg"].imports == ["src"]);
            assert(r.value.projects["ctpg"].libs.length == 0);
            assert(r.value.projects["ctpg"].files.length == 1);
            assert(r.value.projects["ctpg"].files[0].path == "src/ctpg.d");
            assert(r.value.projects["ciprad"].path == "~/ciprad");
            assert(r.value.projects["ciprad"].imports == ["src"]);
            assert(r.value.projects["ciprad"].libs.length == 0);
            assert(r.value.projects["ciprad"].files.length == 1);
            assert(r.value.projects["ciprad"].files[0].path == "src/ciprad.d");
            assert(r.value.projects["zbasud"].path == "~/zbasud");
            assert(r.value.projects["zbasud"].imports == ["src", "ctpg/src", "msgpack-d/src"]);
            assert(r.value.projects["zbasud"].libs == ["ctpg/ctpg.lib", "msgpack-d/msgpack.lib"]);
            assert(r.value.projects["zbasud"].files.length == 1);
            assert(r.value.projects["zbasud"].files[0].path == "src/zbasud.d");
        }
    }
}

struct Data
{
    Project[string] projects;
    long modified;
}

struct Project
{
    string name;
    string path;
    string[] imports;
    string[] libs;
    SourceFile[] files;
}

struct SourceFile
{
    string path;
    string objPath;
    long modified;
}

Project[string] makeAA(Project[] projects)
{
    typeof(return) aa;
    foreach(project; projects){
        aa[project.name] = project;
    }
    return aa;
}

void main(string[] args)
{
    auto release = false, run = false, all = false;
    getopt(args, "release", &release, "run", &run, "all", &all);

    enforce(args.length >= 2, "too few arguments");
    immutable target = args[1];

    version(Windows){
        immutable prefix = environment["USERPROFILE"], objExt = "obj";
    }else version(Posix){
        immutable prefix = environment["HOME"], objExt = "o";
    }else{
        static assert(false);
    }

    immutable projectFile = prefix ~ dirSeparator ~ projectFileName;
    immutable dataFile = prefix ~ dirSeparator ~ dataFileName;
    projectFile.exists().enforce(projectFile ~ " not found");

    auto data = Data.init;

    if(dataFile.exists()){
        unpack(cast(ubyte[])dataFile.read(), data);
        "DataFileLoadedFromFile".writeln();
    }

    immutable modified = projectFile.timeLastModified().stdTime;
    auto recreated = false;
    if(modified > data.modified){
        recreated = true;
        "DataFileRecreated".writeln();
        auto result = projectFile.readText().parse!(Parsers.root)();
        data = result.value;
        data.modified = modified;
        foreach(ref project; data.projects.byValue()){
            if(project.path.startsWith('~'))
            {
                project.path = prefix ~ project.path[1..$];
            }
            foreach(ref file; project.files)
            {
                file.modified = (project.path ~ dirSeparator ~ file.path).timeLastModified().stdTime;
                if(file.path.extension() == ".d")
                {
                    file.objPath = "obj" ~ dirSeparator ~ file.path.stripExtension().setExtension(objExt);
                }
            }
        }
        dataFile.write(pack(data));
    }

    auto project = data.projects[target];
    chdir(project.path);

    runCommands(project, all, release, recreated);
}

void runCommands(Project project, in bool isAll, in bool isRelease, in bool isForce)
{
    immutable imports = project.imports.map!q{"-I" ~ a}().join(" ");
    immutable libs = project.libs.join(" ");
    version(Windows)
    {
        immutable name = project.name.replace('/', '\\');
    }
    else
    {
        immutable name = project.name;
    }
    if(isRelease)
    {
        system(getReleaseCommand(name, project.files, imports, libs));
    }
    else
    {
        if(isAll)
        {
            system(getDebugAllCommand(name, project.files, imports, libs));
        }
        else
        {
            foreach(file; project.files)
            {
                if(file.path.extension() == ".d" && (isForce || !file.objPath.exists() || file.modified < file.path.timeLastModified().stdTime))
                {
                    system(getDebugCompileCommand(file.path, imports));
                }
            }
            system(getDebugCommand(name, project.files, libs));
        }
    }
}

string getDebugAllCommand(in string name, SourceFile[] files, string imports, string libs)
{
    return "dmd -debug -g -unittest -of" ~ name ~ " "  ~ imports ~ " " ~ libs ~ " " ~ files.filter!(file => file.path.extension() == ".d")().map!(file => file.path)().join(" ");
}

string getDebugCompileCommand(in string path, in string imports)
{
    return "dmd -c -debug -g -unittest -op -odobj " ~ imports ~ " " ~ path;
}

unittest
{
    assert(getDebugCompileCommand("src/hoge.d", "-Isrc -Ifuga/src") == "dmd -c -debug -g -unittest -op -odobj -Isrc -Ifuga/src src/hoge.d");
    assert(getDebugCompileCommand("src/foo.d", "-Isrc -Ibar/src") == "dmd -c -debug -g -unittest -op -odobj -Isrc -Ibar/src src/foo.d");
}

string getDebugCommand(string name, SourceFile[] files, string libs)
{
    return "dmd -of" ~ name ~ " " ~ libs ~ " " ~ files.filter!(file => file.path.extension() == ".d")().map!(file => file.objPath)().join(" ");
}

string getReleaseCommand(in string name, SourceFile[] files, in string imports, in string libs)
{
    return "dmd -O -release -inline -of" ~ name ~ " "  ~ imports ~ " " ~ libs ~ " " ~ files.filter!(file => file.path.extension() == ".d")().map!(file => file.path)().join(" ");
}

unittest
{
    assert(getReleaseCommand("hoge", [SourceFile("src/hoge.d")], "-Isrc", "a.lib") == "dmd -O -release -inline -ofhoge -Isrc a.lib src/hoge.d");
}
