#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const androidDir = path.resolve(process.cwd(), 'android');
const appDir = path.join(androidDir, 'app');
const keyPropsPath = path.join(androidDir, 'key.properties');
const defaultKeystoreName = 'waste-release.jks';
const defaultKeystorePath = path.join(appDir, defaultKeystoreName);

const envB64 = (process.env.ANDROID_KEYSTORE_BASE64 || '').replace(/\s+/g, '');
const envStorePass = process.env.ANDROID_KEYSTORE_PASSWORD || '';
const envAlias = process.env.ANDROID_KEY_ALIAS || '';
const envKeyPass = process.env.ANDROID_KEY_PASSWORD || envStorePass;

function escapePropValue(val) {
  return String(val).replace(/\\/g, '\\\\');
}

if (envB64 && envStorePass && envAlias && envKeyPass) {
  fs.mkdirSync(appDir, { recursive: true });
  fs.writeFileSync(defaultKeystorePath, Buffer.from(envB64, 'base64'));
  const propsContent = [
    `storePassword=${escapePropValue(envStorePass)}`,
    `keyPassword=${escapePropValue(envKeyPass)}`,
    `keyAlias=${escapePropValue(envAlias)}`,
    `storeFile=${defaultKeystoreName}`,
    '',
  ].join('\n');
  fs.writeFileSync(keyPropsPath, propsContent, 'utf8');
  console.log(`Configured release keystore at ${defaultKeystorePath}`);
} else if (!fs.existsSync(keyPropsPath)) {
  console.log(
    '::warning::Persistent Android release keystore secrets (ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD) are not set and android/key.properties does not exist. Falling back to ephemeral debug signing (in-place updates across builds will fail until secrets are configured).'
  );
  process.exit(0);
}

const ktsPath = path.join(appDir, 'build.gradle.kts');
const groovyPath = path.join(appDir, 'build.gradle');

if (fs.existsSync(ktsPath)) {
  let content = fs.readFileSync(ktsPath, 'utf8');
  if (!content.includes('keystorePropertiesFile')) {
    const imports = 'import java.io.FileInputStream\nimport java.util.Properties\n\n';
    if (!content.includes('import java.util.Properties')) {
      content = imports + content;
    }

    const propLoader = [
      '',
      'val keystoreProperties = Properties()',
      'val keystorePropertiesFile = rootProject.file("key.properties")',
      'if (keystorePropertiesFile.exists()) {',
      '    keystoreProperties.load(FileInputStream(keystorePropertiesFile))',
      '}',
      '',
    ].join('\n');

    content = content.replace(/(plugins\s*\{[\s\S]*?\n\})/, `$1\n${propLoader}`);

    const signingBlock = [
      '    signingConfigs {',
      '        if (keystorePropertiesFile.exists()) {',
      '            create("release") {',
      '                keyAlias = keystoreProperties.getProperty("keyAlias")',
      '                keyPassword = keystoreProperties.getProperty("keyPassword")',
      '                storeFile = file(keystoreProperties.getProperty("storeFile"))',
      '                storePassword = keystoreProperties.getProperty("storePassword")',
      '            }',
      '        }',
      '    }',
      '',
      '    buildTypes {',
    ].join('\n');

    content = content.replace(/\n\s*buildTypes\s*\{/, `\n${signingBlock}`);
    content = content.replace(
      /signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)/g,
      'signingConfig = if (keystorePropertiesFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")'
    );

    fs.writeFileSync(ktsPath, content, 'utf8');
    console.log(`Patched Kotlin Gradle signing config in ${ktsPath}`);
  } else {
    console.log(`Kotlin Gradle signing config already present in ${ktsPath}`);
  }
} else if (fs.existsSync(groovyPath)) {
  let content = fs.readFileSync(groovyPath, 'utf8');
  if (!content.includes('keystorePropertiesFile')) {
    const propLoader = [
      'def keystoreProperties = new Properties()',
      'def keystorePropertiesFile = rootProject.file("key.properties")',
      'if (keystorePropertiesFile.exists()) {',
      '    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))',
      '}',
      '',
    ].join('\n');

    content = content.replace(/(android\s*\{)/, `${propLoader}\n$1`);

    const signingBlock = [
      '    signingConfigs {',
      '        release {',
      '            if (keystorePropertiesFile.exists()) {',
      '                keyAlias keystoreProperties["keyAlias"]',
      '                keyPassword keystoreProperties["keyPassword"]',
      '                storeFile file(keystoreProperties["storeFile"])',
      '                storePassword keystoreProperties["storePassword"]',
      '            }',
      '        }',
      '    }',
      '',
      '    buildTypes {',
    ].join('\n');

    content = content.replace(/\n\s*buildTypes\s*\{/, `\n${signingBlock}`);
    content = content.replace(
      /signingConfig\s*=?\s*signingConfigs\.debug/g,
      'signingConfig keystorePropertiesFile.exists() ? signingConfigs.release : signingConfigs.debug'
    );

    fs.writeFileSync(groovyPath, content, 'utf8');
    console.log(`Patched Groovy Gradle signing config in ${groovyPath}`);
  } else {
    console.log(`Groovy Gradle signing config already present in ${groovyPath}`);
  }
} else {
  console.error('Neither build.gradle.kts nor build.gradle found in android/app/');
  process.exit(1);
}
