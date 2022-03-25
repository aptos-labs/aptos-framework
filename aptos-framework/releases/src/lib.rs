// Copyright (c) Aptos
// SPDX-License-Identifier: Apache-2.0

use anyhow::Result;
use framework_releases::{Release, ReleaseFetcher};
use move_binary_format::file_format::CompiledModule;
use move_command_line_common::files::{extension_equals, find_filenames, MOVE_COMPILED_EXTENSION};
use once_cell::sync::Lazy;
use std::path::PathBuf;

/// Load the serialized modules from the specified release.
pub fn load_modules_from_release(release_name: &str) -> Result<Vec<Vec<u8>>> {
    ReleaseFetcher::new(Release::Aptos, release_name).module_blobs()
}

static CURRENT_MODULE_BLOBS: Lazy<Vec<Vec<u8>>> =
    Lazy::new(|| load_modules_from_release("current").unwrap());

static CURRENT_MODULES: Lazy<Vec<CompiledModule>> = Lazy::new(|| {
    CURRENT_MODULE_BLOBS
        .iter()
        .map(|blob| CompiledModule::deserialize(blob).unwrap())
        .collect()
});

pub fn current_modules() -> &'static [CompiledModule] {
    &CURRENT_MODULES
}

pub fn current_module_blobs() -> &'static [Vec<u8>] {
    &CURRENT_MODULE_BLOBS
}

/// Load the serialized modules from the specified paths.
pub fn load_modules_from_paths(paths: &[PathBuf]) -> Vec<Vec<u8>> {
    find_filenames(paths, |path| {
        extension_equals(path, MOVE_COMPILED_EXTENSION)
    })
    .expect("module loading failed")
    .iter()
    .map(|file_name| std::fs::read(file_name).unwrap())
    .collect::<Vec<_>>()
}
