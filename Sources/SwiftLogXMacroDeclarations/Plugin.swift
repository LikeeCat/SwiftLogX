//
//  SwiftLogXPlugin.swift
//  SwiftLogX
//
//  Created by Mac on 2025/7/21.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct Plugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        XLogMacro.self,
    ]
}
