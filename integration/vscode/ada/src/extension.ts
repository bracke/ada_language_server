/*----------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                     Copyright (C) 2018-2023, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
----------------------------------------------------------------------------*/

import * as process from 'process';
import * as vscode from 'vscode';
import {
    Disposable,
    ExecuteCommandRequest,
    LanguageClient,
    LanguageClientOptions,
    Middleware,
    ServerOptions,
    SymbolKind,
} from 'vscode-languageclient/node';
import { ALSClientFeatures } from './alsClientFeatures';
import { alsCommandExecutor } from './alsExecuteCommand';
import GnatTaskProvider, { getEnclosingSymbol } from './gnatTaskProvider';
import GprTaskProvider from './gprTaskProvider';
import { getEvaluatedCustomEnv } from './helpers';
import { existsSync } from 'fs';

export let contextClients: ContextClients;
export let mainLogChannel: vscode.OutputChannel;

export class ContextClients {
    public readonly gprClient: LanguageClient;
    public readonly adaClient: LanguageClient;

    private clientsDisposables: Disposable[];
    private registeredTaskProviders: Disposable[];

    constructor(ada: LanguageClient, gpr: LanguageClient) {
        this.gprClient = gpr;
        this.adaClient = ada;
        this.clientsDisposables = [];
        this.registeredTaskProviders = [];
    }

    public start = () => {
        this.clientsDisposables = [this.gprClient.start(), this.adaClient.start()];
        this.registerTaskProviders();
    };

    public dispose = () => {
        this.unregisterTaskProviders();
        this.clientsDisposables.forEach((clientDisposable: Disposable) =>
            clientDisposable.dispose()
        );
    };

    public registerTaskProviders = (): void => {
        this.registeredTaskProviders = [
            vscode.tasks.registerTaskProvider(GnatTaskProvider.gnatType, new GnatTaskProvider()),
            vscode.tasks.registerTaskProvider(
                GprTaskProvider.gprTaskType,
                new GprTaskProvider(this.adaClient)
            ),
        ];
    };

    public unregisterTaskProviders = (): void => {
        for (const item of this.registeredTaskProviders) {
            item.dispose();
        }
        this.registeredTaskProviders = [];
    };

    //  React to changes in configuration to recompute predefined tasks if the user
    //  changes scenario variables' values.
    public configChanged = (e: vscode.ConfigurationChangeEvent) => {
        if (
            e.affectsConfiguration('ada.scenarioVariables') ||
            e.affectsConfiguration('ada.projectFile')
        ) {
            this.unregisterTaskProviders();
            this.registerTaskProviders();
        }
    };

    //  Take active editor URI and call execute 'als-other-file' command in LSP
    public otherFileHandler = () => {
        const activeEditor = vscode.window.activeTextEditor;
        if (!activeEditor) {
            return;
        }
        void this.adaClient.sendRequest(ExecuteCommandRequest.type, {
            command: 'als-other-file',
            arguments: [
                {
                    uri: activeEditor.document.uri.toString(),
                },
            ],
        });
    };
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    // Create an output channel for the extension. There are dedicated channels
    // for the Ada and Gpr language servers, and this one is a general channel
    // for non-LSP features of the extension.
    mainLogChannel = vscode.window.createOutputChannel('Ada Extension');
    mainLogChannel.appendLine('Starting Ada extension');

    context.subscriptions.push(
        vscode.commands.registerCommand('ada.showExtensionOutput', () => mainLogChannel.show())
    );

    assertSupportedEnvironments();

    // Log the environment that the extension (and all VS Code) will be using
    const customEnv = getEvaluatedCustomEnv();

    if (customEnv && Object.keys(customEnv).length > 0) {
        mainLogChannel.appendLine('Setting environment variables:');
        for (const varName in customEnv) {
            const varValue: string = customEnv[varName];
            mainLogChannel.appendLine(`${varName}=${varValue}`);
        }
    }

    // Create the GPR language client and start it.
    const gprClient = createClient(
        context,
        'gpr',
        'GPR Language Server',
        ['--language-gpr'],
        '**/.{gpr}'
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('ada.showGprLSOutput', () => gprClient.outputChannel.show())
    );
    // Create the Ada language client and start it.
    const alsClient = createClient(
        context,
        'ada',
        'Ada Language Server',
        [],
        '**/.{adb,ads,adc,ada}'
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('ada.showAdaLSOutput', () => alsClient.outputChannel.show())
    );
    const alsMiddleware: Middleware = {
        executeCommand: alsCommandExecutor(alsClient),
    };
    alsClient.clientOptions.middleware = alsMiddleware;
    alsClient.registerFeature(new ALSClientFeatures());

    contextClients = new ContextClients(alsClient, gprClient);
    contextClients.start();
    context.subscriptions.push(contextClients);

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(contextClients.configChanged)
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('ada.otherFile', contextClients.otherFileHandler)
    );
    context.subscriptions.push(
        vscode.commands.registerCommand('ada.subprogramBox', addSupbrogramBox)
    );
    await Promise.all([alsClient.onReady(), gprClient.onReady()]);
    await checkSrcDirectories(alsClient);
    mainLogChannel.appendLine('Started Ada extension');
}

function createClient(
    context: vscode.ExtensionContext,
    id: string,
    name: string,
    extra: string[],
    pattern: string
) {
    let serverExecPath: string;

    if (process.arch == 'arm64' && process.platform == 'darwin') {
        // On arm64 darwin use the x64 darwin executable thanks to Apple Rosetta.
        serverExecPath = context.asAbsolutePath(`x64/darwin/ada_language_server`);
    } else {
        serverExecPath = context.asAbsolutePath(
            `${process.arch}/${process.platform}/ada_language_server`
        );
    }

    if (process.platform == 'win32') {
        // Add the extension for the file lookup further below
        serverExecPath = `${serverExecPath}.exe`;
    }

    // If the ALS environment variable is specified, use it as the path of the
    // server executable.
    if (process.env.ALS) {
        serverExecPath = process.env.ALS;
        if (!existsSync(serverExecPath)) {
            logErrorAndThrow(
                `The Ada language server given in the ALS environment ` +
                    `variable does not exist: ${serverExecPath}`
            );
        }
    } else {
        if (!existsSync(serverExecPath)) {
            logErrorAndThrow(
                `This installation of the Ada extension does not have the Ada ` +
                    `language server for your architecture (${process.arch}) ` +
                    `and platform (${process.platform}) ` +
                    `at the expected location: ${serverExecPath}`
            );
        }
    }

    // The debug options for the server
    // let debugOptions = { execArgv: [] };
    // If the extension is launched in debug mode then the debug server options are used
    // Otherwise the run options are used

    // Retrieve the user's custom environment variables if specified in their
    // settings/workspace: we'll then launch any child process with this custom
    // environment
    const custom_env = getEvaluatedCustomEnv();

    if (custom_env) {
        for (const var_name in custom_env) {
            const var_value: string = custom_env[var_name];
            process.env[var_name] = var_value;
        }
    }

    // Options to control the server
    const serverOptions: ServerOptions = {
        run: { command: serverExecPath, args: extra },
        debug: { command: serverExecPath, args: extra },
    };

    // Options to control the language client
    const clientOptions: LanguageClientOptions = {
        // Register the server for ada sources documents
        documentSelector: [{ scheme: 'file', language: id }],
        synchronize: {
            // Synchronize the setting section 'ada' to the server
            configurationSection: 'ada',
            // Notify the server about file changes to Ada files contain in the workspace
            fileEvents: vscode.workspace.createFileSystemWatcher(pattern),
        },
    };
    // Create the language client
    return new LanguageClient(id, name, serverOptions, clientOptions);
}

/**
 * Add a subprogram box above the subprogram enclosing the cursor's position, if any.
 *
 * @example
 *
 *  -------
 *  - Foo -
 *  -------
 *
 *  procedure Foo is
 */
async function addSupbrogramBox() {
    const activeEditor = vscode.window.activeTextEditor;

    await getEnclosingSymbol(activeEditor, [SymbolKind.Function, SymbolKind.Module]).then(
        async (symbol) => {
            if (symbol !== null) {
                const name: string = symbol.name ?? '';
                const insertPos = new vscode.Position(symbol.range.start.line, 0);
                const indentationRange = new vscode.Range(insertPos, symbol.range.start);
                const indentation: string = activeEditor?.document.getText(indentationRange) ?? '';
                const eol: string =
                    activeEditor?.document.eol == vscode.EndOfLine.CRLF ? '\r\n' : '\n';

                // Generate the subprogram box after retrieving the indentation of the line of
                // the subprogram's body declaration.
                const text: string =
                    indentation +
                    '---' +
                    '-'.repeat(name.length) +
                    '---' +
                    eol +
                    indentation +
                    '-- ' +
                    name +
                    ' --' +
                    eol +
                    indentation +
                    '---' +
                    '-'.repeat(name.length) +
                    '---' +
                    eol +
                    eol;

                if (activeEditor) {
                    await activeEditor.edit((editBuilder) => {
                        editBuilder.insert(insertPos, text);
                    });
                }
            }
        }
    );
}

type ALSSourceDirDescription = {
    name: string;
    uri: string;
};

/**
 *
 * Check if we need to add some source directories to the workspace (e.g: when imported
 * projects' source directories are not placed under the root project's directory).
 * Do nothing is the user did not setup any workspace file.
 *
 */
async function checkSrcDirectories(alsClient: LanguageClient) {
    if (vscode.workspace.workspaceFile !== undefined) {
        await alsClient
            .sendRequest<[ALSSourceDirDescription]>('workspace/alsSourceDirs')
            .then(async (source_dirs) => {
                const workspace_folders = vscode.workspace.workspaceFolders ?? [];
                const workspace_dirs_to_add: { uri: vscode.Uri; name?: string | undefined }[] = [];

                for (const source_dir of source_dirs) {
                    const source_dir_uri = vscode.Uri.parse(source_dir.uri);
                    const source_dir_path = source_dir_uri.path;

                    const is_subdirectory = (dir: string, parent: string) => {
                        //  Use lower-case on Windows since drives can be specified in VS Code
                        //  either with lower or upper case characters.
                        if (process.platform == 'win32') {
                            dir = dir.toLowerCase();
                            parent = parent.toLowerCase();
                        }

                        return dir.startsWith(parent + '/');
                    };

                    //  If the source directory is not under one of the workspace folders, push
                    //  this source directory to the workspace folders to add later.
                    if (
                        !workspace_folders.some((workspace_folder) =>
                            is_subdirectory(source_dir_path, workspace_folder.uri.path)
                        )
                    ) {
                        workspace_dirs_to_add.push({
                            name: source_dir.name,
                            uri: source_dir_uri,
                        });
                    }
                }

                //  If there are some source directories missing in the workspace, ask the user
                //  to add them in his workspace.
                if (workspace_dirs_to_add.length > 0) {
                    await vscode.window
                        .showInformationMessage(
                            'Some project source directories are not ',
                            'listed in your workspace: do you want to add them?',
                            'Yes',
                            'No'
                        )
                        .then((answer) => {
                            if (answer === 'Yes') {
                                for (const workspace_dir of workspace_dirs_to_add) {
                                    vscode.workspace.updateWorkspaceFolders(
                                        vscode.workspace.workspaceFolders
                                            ? vscode.workspace.workspaceFolders.length
                                            : 0,
                                        null,
                                        workspace_dir
                                    );
                                }
                            }
                        });
                }
            });
    }
}

function assertSupportedEnvironments() {
    type Env = {
        arch: 'arm' | 'arm64' | 'x64';
        platform: 'win32' | 'linux' | 'darwin';
    };
    const supportedEnvs: Env[] = [
        { arch: 'x64', platform: 'linux' },
        { arch: 'x64', platform: 'win32' },
        { arch: 'x64', platform: 'darwin' },
        { arch: 'arm64', platform: 'darwin' },
    ];

    if (
        !supportedEnvs.some((val) => {
            return val.arch == process.arch && val.platform == process.platform;
        })
    ) {
        const msg =
            `The Ada extension is not supported on ` +
            `architecture '${process.arch}' and platform '${process.platform}'`;
        logErrorAndThrow(msg);
    }
}

function logErrorAndThrow(msg: string) {
    void vscode.window.showErrorMessage(msg);
    mainLogChannel.appendLine('[Error] ' + msg);
    throw new Error(msg);
}
