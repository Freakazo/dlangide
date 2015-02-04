module dlangide.ui.dsourceedit;

import dlangui.core.logger;
import dlangui.widgets.editors;
import dlangui.widgets.srcedit;
import dlangui.widgets.widget;

import ddc.lexer.textsource;
import ddc.lexer.exceptions;
import ddc.lexer.tokenizer;

import dlangide.workspace.workspace;
import dlangide.workspace.project;
import dlangide.ui.commands;
import dlangide.builders.extprocess;
import dlangide.ui.frame;

import std.algorithm;
import std.conv;
import std.stdio;
import std.string;

interface SourceFileSelectionHandler {
    bool onSourceFileSelected(ProjectSourceFile file, bool activate);
}

/// DIDE source file editor
class DSourceEdit : SourceEdit {
	this(string ID) {
		super(ID);
		styleId = null;
		backgroundColor = 0xFFFFFF;
        setTokenHightlightColor(TokenCategory.Comment, 0x008000); // green
        setTokenHightlightColor(TokenCategory.Keyword, 0x0000FF); // blue
        setTokenHightlightColor(TokenCategory.String, 0xA31515);  // brown
        setTokenHightlightColor(TokenCategory.Character, 0xA31515);  // brown
        setTokenHightlightColor(TokenCategory.Error, 0xFF0000);  // red
        setTokenHightlightColor(TokenCategory.Comment_Documentation, 0x206000);
        //setTokenHightlightColor(TokenCategory.Identifier, 0x206000);  // no colors
	}
	this() {
		this("SRCEDIT");
	}

    IDEFrame _frame = null;

    /// handle source file selection change
    Signal!SourceFileSelectionHandler sourceFileSelectionListener;

    protected ProjectSourceFile _projectSourceFile;
    @property ProjectSourceFile projectSourceFile() { return _projectSourceFile; }
    /// load by filename
    override bool load(string fn) {
        _projectSourceFile = null;
        bool res = super.load(fn);
        setHighlighter();
        return res;
    }

    void setHighlighter() {
        if (filename.endsWith(".d") || filename.endsWith(".dd") || filename.endsWith(".dh") || filename.endsWith(".ddoc")) {
            content.syntaxHighlighter = new SimpleDSyntaxHighlighter(filename);
        } else {
            content.syntaxHighlighter = null;
        }
    }

    /// load by project item
    bool load(ProjectSourceFile f) {
        if (!load(f.filename)) {
            _projectSourceFile = null;
            return false;
        }
        _projectSourceFile = f;
        setHighlighter();
        return true;
    }

    /// save to the same file
    bool save() {
        return _content.save();
    }

    /// override to handle specific actions
	override bool handleAction(const Action a) {
        if (a) {
            switch (a.id) {
                case IDEActions.FileSave:
                    save();
                    return true;
                default:
                    break;
            }
        }
        return super.handleAction(a);
    }
    

    override bool onMouseEvent(MouseEvent event){
        super.onMouseEvent(event);
        ExternalProcess dcdProcess = new ExternalProcess();
        char[][] args;
        args ~= ["-l".dup, "-c".dup];
        auto line = 0;
        auto pos = 0;
        auto bytes = 0;
        dchar[] fileText = text.dup;
        foreach(c; fileText) {
            bytes++;
            if(c == '\n') {
                line++;
            }
            if(line == _caretPos.line) {
                if(pos == _caretPos.pos)
                    break;
                pos++;
            }
        }
        args ~= [to!string(bytes).dup];
        args ~= [_projectSourceFile.filename().dup];

        ProtectedTextStorage stdoutTarget = new ProtectedTextStorage();
        if(event.lbutton().isDown() && isCtrlPressed == true) {
            auto state = dcdProcess.run("dcd-client".dup, args, "/usr/bin".dup, stdoutTarget);
            while(dcdProcess.poll() == ExternalProcessState.Running){ }
            string[] outputLines = to!string(stdoutTarget.readText()).splitLines();
            //TODO: Process output from DCD.
            foreach(string outputLine ; outputLines) {
                if(outputLine.indexOf("Not Found".dup) == -1) {
                    auto split = outputLine.indexOf("\t");
                    if(split == -1) {
                        writeln("Could not find split");
                        continue;
                    }
                    if(indexOf(outputLine[0 .. split],"stdin".dup) != -1) {
                        writeln("Declaration is in current file. Can jump to it.");
                        line = 0;
                        pos = 0;
                        bytes = 0;
                        auto target = to!int(outputLine[split+1 .. $]);
                        foreach(c; fileText) {
                            if(bytes == target) {
                                //We all good.
                                _caretPos.line = line;
                                _caretPos.pos = pos;
                            }
                            bytes++;
                            if(c == '\n')
                            {
                                line++;
                                pos = 0;
                            }
                            else
                                pos++;
                        }
                    }
                    else {
                        ProjectSourceFile sourceFile = new ProjectSourceFile(outputLine[0 .. split]);
                        if(_frame !is null) {
                            writeln("Well I'm trying");
                            load(outputLine[0 .. split]);
                            _frame.openSourceFile(outputLine[0 .. split],projectSourceFile);
                            writeln("Well I tried");
                        }
                    }
                    writeln("Before Split ", outputLine[0 .. split]);
                    writeln("After Split ", outputLine[split+1 .. $]);
                }
                else {
                    writeln("Declaration not found");
                }
            }

        }
        return true;
    }

    bool isCtrlPressed = false;

    override bool onKeyEvent(KeyEvent event){

        if(event.action() == KeyAction.KeyDown && event.keyCode() == KeyCode.LCONTROL) {
            isCtrlPressed = true;
            writeln("Ctrl is pressed");
        }
        else if(event.action() == KeyAction.KeyUp && event.keyCode() == KeyCode.LCONTROL) {
            isCtrlPressed = false;
        }
        return super.onKeyEvent(event);
    }
}



class SimpleDSyntaxHighlighter : SyntaxHighlighter {

    SourceFile _file;
    ArraySourceLines _lines;
    Tokenizer _tokenizer;
    this (string filename) {
        _file = new SourceFile(filename);
        _lines = new ArraySourceLines();
        _tokenizer = new Tokenizer(_lines);
        _tokenizer.errorTolerant = true;
    }

    TokenPropString[] _props;

    /// categorize characters in content by token types
    void updateHighlight(dstring[] lines, TokenPropString[] props, int changeStartLine, int changeEndLine) {
        //Log.d("updateHighlight");
        long ms0 = currentTimeMillis();
        _props = props;
        changeStartLine = 0;
        changeEndLine = cast(int)lines.length;
        _lines.init(lines[changeStartLine..$], _file, changeStartLine);
        _tokenizer.init(_lines);
        int tokenPos = 0;
        int tokenLine = 0;
        ubyte category = 0;
        try {
            for (;;) {
                Token token = _tokenizer.nextToken();
                if (token is null) {
                    //Log.d("Null token returned");
                    break;
                }
                if (token.type == TokenType.EOF) {
                    //Log.d("EOF token");
                    break;
                }
                uint newPos = token.pos - 1;
                uint newLine = token.line - 1;

                //Log.d("", token.line, ":", token.pos, "\t", tokenLine + 1, ":", tokenPos + 1, "\t", token.toString);

                // fill with category
                for (int i = tokenLine; i <= newLine; i++) {
                    int start = i > tokenLine ? 0 : tokenPos;
                    int end = i < newLine ? cast(int)lines[i].length : newPos;
                    for (int j = start; j < end; j++)
                        _props[i][j] = category;
                }

                // handle token - convert to category
                switch(token.type) {
                    case TokenType.COMMENT:
                        category = token.isDocumentationComment ? TokenCategory.Comment_Documentation : TokenCategory.Comment;
                        break;
                    case TokenType.KEYWORD:
                        category = TokenCategory.Keyword;
                        break;
                    case TokenType.IDENTIFIER:
                        category = TokenCategory.Identifier;
                        break;
                    case TokenType.STRING:
                        category = TokenCategory.String;
                        break;
                    case TokenType.CHARACTER:
                        category = TokenCategory.Character;
                        break;
                    case TokenType.INTEGER:
                        category = TokenCategory.Integer;
                        break;
                    case TokenType.FLOAT:
                        category = TokenCategory.Float;
                        break;
                    case TokenType.INVALID:
                        switch (token.invalidTokenType) {
                            case TokenType.IDENTIFIER:
                                category = TokenCategory.Error_InvalidIdentifier;
                                break;
                            case TokenType.STRING:
                                category = TokenCategory.Error_InvalidString;
                                break;
                            case TokenType.COMMENT:
                                category = TokenCategory.Error_InvalidComment;
                                break;
                            case TokenType.FLOAT:
                            case TokenType.INTEGER:
                                category = TokenCategory.Error_InvalidNumber;
                                break;
                            default:
                                category = TokenCategory.Error;
                                break;
                        }
                        break;
                    default:
                        category = 0;
                        break;
                }
                tokenPos = newPos;
                tokenLine= newLine;

            }
        } catch (Exception e) {
            Log.e("exception while trying to parse D source", e);
        }
        _lines.close();
        _props = null;
		long elapsed = currentTimeMillis() - ms0;
		if (elapsed > 20)
			Log.d("updateHighlight took ", elapsed, "ms");
    }
}

