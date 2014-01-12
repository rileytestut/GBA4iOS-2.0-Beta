//
//  GBAROMTableViewController.m
//  GBA4iOS
//
//  Created by Riley Testut on 7/18/13.
//  Copyright (c) 2013 Riley Testut. All rights reserved.
//

#import "GBAROMTableViewController.h"
#import "GBAEmulationViewController.h"
#import "GBASettingsViewController.h"
#import "GBAROM_Private.h"
#import "RSTFileBrowserTableViewCell+LongPressGestureRecognizer.h"
#import "GBAMailActivity.h"
#import "GBASplitViewController.h"
#import "UITableViewController+Theming.h"
#import "GBAControllerSkin.h"
#import "GBASyncManager.h"
#import "GBASyncingDetailViewController.h"
#import "GBAAppDelegate.h"

#import <RSTWebViewController.h>
#import "UIAlertView+RSTAdditions.h"
#import "UIActionSheet+RSTAdditions.h"

#import <SSZipArchive/minizip/SSZipArchive.h>
#import <DropboxSDK/DropboxSDK.h>

#define LEGAL_NOTICE_ALERT_TAG 15
#define NAME_ROM_ALERT_TAG 17
#define DELETE_ROM_ALERT_TAG 2
#define RENAME_GESTURE_RECOGNIZER_TAG 22

static void * GBADownloadROMProgressContext = &GBADownloadROMProgressContext;

typedef NS_ENUM(NSInteger, GBAVisibleROMType) {
    GBAVisibleROMTypeAll,
    GBAVisibleROMTypeGBA,
    GBAVisibleROMTypeGBC,
};

@interface GBAROMTableViewController () <RSTWebViewControllerDownloadDelegate, UIAlertViewDelegate, UIViewControllerTransitioningDelegate, UIPopoverControllerDelegate, RSTWebViewControllerDelegate, GBASettingsViewControllerDelegate, GBASyncingDetailViewControllerDelegate>
{
    BOOL _performedInitialRefreshDirectory;
}

@property (assign, nonatomic) GBAVisibleROMType visibleRomType;
@property (weak, nonatomic) IBOutlet UISegmentedControl *romTypeSegmentedControl;
@property (strong, nonatomic) NSMutableSet *currentUnzippingOperations;
@property (strong, nonatomic) UIProgressView *downloadProgressView;
@property (weak, nonatomic) IBOutlet UIBarButtonItem *settingsButton;
@property (strong, nonatomic) UIPopoverController *activityPopoverController;
@property (strong, nonatomic) dispatch_queue_t directory_contents_changed_queue;

@property (strong, nonatomic) NSProgress *downloadProgress;
@property (strong, nonatomic) NSMutableDictionary *currentDownloadsDictionary;

- (IBAction)switchROMTypes:(UISegmentedControl *)segmentedControl;
- (IBAction)searchForROMs:(UIBarButtonItem *)barButtonItem;
- (IBAction)presentSettings:(UIBarButtonItem *)barButtonItem;

@end

@implementation GBAROMTableViewController
@synthesize theme = _theme;

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    self = [storyboard instantiateViewControllerWithIdentifier:@"romTableViewController"];
    if (self)
    {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
        
        self.currentDirectory = documentsDirectory; 
        self.showFileExtensions = YES;
        self.showFolders = NO;
        self.showSectionTitles = NO;
        self.showUnavailableFiles = YES;
        
        self.directory_contents_changed_queue = dispatch_queue_create("com.rileytestut.GBA4iOS.directory_contents_changed_queue", DISPATCH_QUEUE_SERIAL);
        
        _downloadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
        [_downloadProgress addObserver:self
                    forKeyPath:@"fractionCompleted"
                       options:NSKeyValueObservingOptionNew
                       context:GBADownloadROMProgressContext];
        
        _currentDownloadsDictionary = [NSMutableDictionary dictionary];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userRequestedToPlayROM:) name:GBAUserRequestedToPlayROMNotification object:nil];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view.
    
    self.clearsSelectionOnViewWillAppear = YES;
    
    GBAVisibleROMType romType = (GBAVisibleROMType)[[NSUserDefaults standardUserDefaults] integerForKey:@"visibleROMType"];
    self.romType = romType;
    
    self.downloadProgressView = ({
        UIProgressView *progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        progressView.frame = CGRectMake(0,
                                        CGRectGetHeight(self.navigationController.navigationBar.bounds) - CGRectGetHeight(progressView.bounds),
                                        CGRectGetWidth(self.navigationController.navigationBar.bounds),
                                        CGRectGetHeight(progressView.bounds));
        progressView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        progressView.trackTintColor = [UIColor clearColor];
        progressView.progress = 0.0;
        progressView.alpha = 0.0;
        [self.navigationController.navigationBar addSubview:progressView];
        progressView;
    });
    
    [self.tableView registerClass:[UITableViewHeaderFooterView class] forHeaderFooterViewReuseIdentifier:@"Header"];
    
    [self importDefaultSkins];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [[UIApplication sharedApplication] setStatusBarStyle:[self preferredStatusBarStyle] animated:YES];
        
    // Sometimes it loses its color when the view appears
    self.downloadProgressView.progressTintColor = GBA4iOS_PURPLE_COLOR;
    
    if ([self.appearanceDelegate respondsToSelector:@selector(romTableViewControllerWillAppear:)])
    {
        [self.appearanceDelegate romTableViewControllerWillAppear:self];
    }
    
    if (self.emulationViewController.rom && [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) // Show selected ROM
    {
        [self.tableView reloadData];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    if ([self.appearanceDelegate respondsToSelector:@selector(romTableViewControllerWillDisappear:)])
    {
        [self.appearanceDelegate romTableViewControllerWillDisappear:self];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        DLog(@"ROM list appeared");
    });
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    
    self.romTypeSegmentedControl.frame = ({
        CGRect frame = self.romTypeSegmentedControl.frame;
        frame.size.width = self.navigationController.navigationBar.bounds.size.width - (self.navigationItem.leftBarButtonItem.width + self.navigationItem.rightBarButtonItem.width);
        
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone)
        {
            if (UIInterfaceOrientationIsPortrait(self.interfaceOrientation))
            {
                frame.size.height = 29.0f;
            }
            else
            {
                frame.size.height = 25.0f;
            }
        }
        
        frame;
    });
}

- (BOOL)prefersStatusBarHidden
{
    return NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    if (self.theme == GBAThemedTableViewControllerThemeOpaque)
    {
        return UIStatusBarStyleDefault;
    }
    
    return UIStatusBarStyleLightContent;
}

#pragma mark - RSTWebViewController delegate

- (BOOL)webViewController:(RSTWebViewController *)webViewController shouldInterceptDownloadRequest:(NSURLRequest *)request
{
    NSString *fileExtension = request.URL.pathExtension.lowercaseString;
    
    if (([fileExtension isEqualToString:@"gb"] || [fileExtension isEqualToString:@"gbc"] || [fileExtension isEqualToString:@"gba"] || [fileExtension isEqualToString:@"zip"]) || [request.URL.host hasPrefix:@"dl.coolrom"])
    {
        return YES;
    }
    
    return NO;
}

- (void)webViewController:(RSTWebViewController *)webViewController shouldStartDownloadTask:(NSURLSessionDownloadTask *)downloadTask startDownloadBlock:(RSTWebViewControllerStartDownloadBlock)startDownloadBlock
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"By tapping “Download” below, you confirm that you legally own a physical copy of this ROM. GBA4iOS does not promote pirating in any form.", @"")
                                                    message:nil delegate:nil cancelButtonTitle:NSLocalizedString(@"Cancel", @"") otherButtonTitles:NSLocalizedString(@"Download", @""), nil];
    alert.tag = LEGAL_NOTICE_ALERT_TAG;
    dispatch_async(dispatch_get_main_queue(), ^{
        [alert showWithSelectionHandler:^(UIAlertView *alertView, NSInteger buttonIndex) {
            
            if (buttonIndex == 1)
            {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Name", @"")
                                                                message:nil
                                                               delegate:self
                                                      cancelButtonTitle:NSLocalizedString(@"Cancel", @"") otherButtonTitles:NSLocalizedString(@"Save", @""), nil];
                alert.alertViewStyle = UIAlertViewStylePlainTextInput;
                alert.tag = NAME_ROM_ALERT_TAG;
                
                UITextField *textField = [alert textFieldAtIndex:0];
                textField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
                
                [alert showWithSelectionHandler:^(UIAlertView *namingAlertView, NSInteger namingButtonIndex) {
                    
                    if (namingButtonIndex == 1)
                    {
                        NSString *filename = [[namingAlertView textFieldAtIndex:0] text];
                        [self startDownloadWithFilename:filename downloadTask:downloadTask startDownloadBlock:startDownloadBlock];
                    }
                    else
                    {
                        startDownloadBlock(NO, nil);
                    }
                    
                }];
            }
            else
            {
                startDownloadBlock(NO, nil);
            }
            
        }];
    });
}

- (void)startDownloadWithFilename:(NSString *)filename downloadTask:(NSURLSessionDownloadTask *)downloadTask startDownloadBlock:(RSTWebViewControllerStartDownloadBlock)startDownloadBlock
{
    if ([filename length] == 0)
    {
        filename = @" ";
    }
    
    NSString *fileExtension = downloadTask.originalRequest.URL.pathExtension;
    
    if (fileExtension == nil || [fileExtension isEqualToString:@""])
    {
        fileExtension = @"zip";
    }
    
    filename = [filename stringByAppendingPathExtension:fileExtension];
    
    if (self.downloadProgressView.alpha == 0)
    {
        rst_dispatch_sync_on_main_thread(^{
            [self showDownloadProgressView];
        });
    }
    
    [self.downloadProgress setTotalUnitCount:self.downloadProgress.totalUnitCount + 1];
    [self.downloadProgress becomeCurrentWithPendingUnitCount:1];
    
    NSProgress *progress = [[NSProgress alloc] initWithParent:[NSProgress currentProgress] userInfo:@{@"filename": filename}];
    
    [self.downloadProgress resignCurrent];
    
    self.currentDownloadsDictionary[downloadTask] = filename;
    
    // Write temp file so it shows up in the file browser, but we'll then gray it out.
    [filename writeToFile:[self.currentDirectory stringByAppendingPathComponent:filename] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    startDownloadBlock(YES, progress);
    
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)webViewController:(RSTWebViewController *)webViewController didCompleteDownloadTask:(NSURLSessionDownloadTask *)downloadTask destinationURL:(NSURL *)url error:(NSError *)error
{
    NSString *filename = self.currentDownloadsDictionary[downloadTask];
    NSString *destinationPath = [self.currentDirectory stringByAppendingPathComponent:filename];
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    
    [self setIgnoreDirectoryContentChanges:YES];
    
    // Delete temporary file
    [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:&error];
    
    if (error)
    {
        ELog(error);
    }
    else
    {
        [[NSFileManager defaultManager] moveItemAtURL:url toURL:destinationURL error:nil];
    }
    
    [self setIgnoreDirectoryContentChanges:NO];
    
    // Must go after file system changes
    [self.currentDownloadsDictionary removeObjectForKey:downloadTask];
    
    if ([self.currentDownloadsDictionary count] == 0)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.downloadProgressView setProgress:1.0 animated:YES];
            [self hideDownloadProgressView];
        });
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == GBADownloadROMProgressContext)
    {
        NSProgress *progress = object;
        
        if (progress.fractionCompleted > 0)
        {
            dispatch_async(dispatch_get_main_queue(), ^{                
                [self.downloadProgressView setProgress:progress.fractionCompleted animated:YES];
            });
        }
        
        return;
    }
    
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)webViewControllerWillDismiss:(RSTWebViewController *)webViewController
{
    [self dismissedModalViewController];
}

#pragma mark - UITableViewController data source

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    RSTFileBrowserTableViewCell *cell = (RSTFileBrowserTableViewCell *)[super tableView:tableView cellForRowAtIndexPath:indexPath];
    
    NSString *filename = [self filenameForIndexPath:indexPath];
    
    [self themeTableViewCell:cell];
    
    NSString *lowercaseFileExtension = [filename.pathExtension lowercaseString];
    
    if ([self isDownloadingFile:filename] || [self.unavailableFiles containsObject:filename])
    {
        cell.userInteractionEnabled = NO;
        cell.textLabel.textColor = [UIColor grayColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    else if ([lowercaseFileExtension isEqualToString:@"zip"])
    {
        // Allows user to delete zip files if they're not being downloaded, but we'll still prevent them from opening them
        cell.userInteractionEnabled = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textColor = [UIColor grayColor];
    }
    else
    {
        GBAROMType romType = GBAROMTypeGBA;
        
        if ([lowercaseFileExtension isEqualToString:@"gbc"] || [lowercaseFileExtension isEqualToString:@"gb"])
        {
            romType = GBAROMTypeGBC;
        }
        
        // Use name so we don't have to load a uniqueName from disk for every cell
        if ([self.emulationViewController.rom.name isEqualToString:[filename stringByDeletingPathExtension]] && self.emulationViewController.rom.type == romType)
        {
            [self highlightCell:cell];
        }
        
        cell.userInteractionEnabled = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    
    if (cell.longPressGestureRecognizer == nil)
    {
        UILongPressGestureRecognizer *longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(didDetectLongPressGesture:)];
        [cell setLongPressGestureRecognizer:longPressGestureRecognizer];
    }
    
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return UITableViewAutomaticDimension;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UITableViewHeaderFooterView *headerView = [self.tableView dequeueReusableHeaderFooterViewWithIdentifier:@"Header"];
    [self themeHeader:headerView];
    
    return headerView;
}

#pragma mark - RSTFileBrowserViewController

- (NSString *)visibleFileExtensionForIndexPath:(NSIndexPath *)indexPath
{
    NSString *extension = [[super visibleFileExtensionForIndexPath:indexPath] uppercaseString];
    
    if ([extension isEqualToString:@"GB"])
    {
        extension = @"GBC";
    }
    
    return [extension copy];
}

- (void)didRefreshCurrentDirectory
{
    [super didRefreshCurrentDirectory];
    
    if ([self ignoreDirectoryContentChanges])
    {
        return;
    }
    
    // Sometimes pesky invisible files remain unavailable after a download, so we filter them out
    BOOL unavailableFilesContainsVisibleFile = NO;
    
    for (NSString *filename in [self unavailableFiles])
    {
        if ([filename length] > 0 && ![[filename substringWithRange:NSMakeRange(0, 1)] isEqualToString:@"."])
        {
            unavailableFilesContainsVisibleFile = YES;
            break;
        }
    }
    
    if ([[self unavailableFiles] count] > 0 && !unavailableFilesContainsVisibleFile)
    {
        return;
    }
    
    dispatch_async(self.directory_contents_changed_queue, ^{
        
        NSMutableDictionary *cachedROMs = [NSMutableDictionary dictionaryWithContentsOfFile:[self cachedROMsPath]];
        
        if (cachedROMs == nil)
        {
            cachedROMs = [NSMutableDictionary dictionary];
        }
        
        NSArray *contents = [self allFiles];
        
        for (NSString *filename in contents)
        {
            NSString *filepath = [self.currentDirectory stringByAppendingPathComponent:filename];
            
            if (([[[filename pathExtension] lowercaseString] isEqualToString:@"zip"] && ![self isDownloadingFile:filename] && ![self.unavailableFiles containsObject:filename]))
            {
                DLog(@"Unzipping.. %@", filename);
                
                NSError *error = nil;
                if (![GBAROM unzipROMAtPathToROMDirectory:filepath withPreferredROMTitle:[filename stringByDeletingPathExtension] error:&error])
                {
                    if ([error code] == NSFileWriteFileExistsError)
                    {
                        // Same as below when importing ROM file
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Already Exists", @"")
                                                                            message:NSLocalizedString(@"Only one copy of a game is supported at a time. To use a new version of this game, please delete the previous version and try again.", @"")
                                                                           delegate:nil
                                                                  cancelButtonTitle:NSLocalizedString(@"Dismiss", @"") otherButtonTitles:nil];
                            [alert show];
                        });
                        
                        [[NSFileManager defaultManager] removeItemAtPath:filepath error:nil];
                    }
                    else if ([error code] == NSFileReadNoSuchFileError)
                    {
                        // Too many false positives
                        /*
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Unsupported File", @"")
                                                                            message:NSLocalizedString(@"Make sure the zip file contains either a GBA or GBC ROM and try again.", @"")
                                                                           delegate:nil
                                                                  cancelButtonTitle:NSLocalizedString(@"Dismiss", @"") otherButtonTitles:nil];
                            [alert show];
                        });*/
                        
                    }
                    else if ([error code] == NSFileWriteInvalidFileNameError)
                    {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Already Exists With This Name", @"")
                                                                            message:NSLocalizedString(@"Please rename either the existing file or the file to be imported and try again.", @"")
                                                                           delegate:nil
                                                                  cancelButtonTitle:NSLocalizedString(@"Dismiss", @"") otherButtonTitles:nil];
                            [alert show];
                        });
                        
                        [[NSFileManager defaultManager] removeItemAtPath:filepath error:nil];
                    }
                    
                    continue;
                }
                
                [[NSFileManager defaultManager] removeItemAtPath:filepath error:nil];
                
                continue;
            }
            
            if (cachedROMs[filename])
            {
                continue;
            }
            
            // VERY important this remains here, or else the hash won't be the same as the final one
            if ([self.unavailableFiles containsObject:filename] || [self isDownloadingFile:filename])
            {
                continue;
            }
            
            GBAROM *rom = [GBAROM romWithContentsOfFile:[self.currentDirectory stringByAppendingPathComponent:filename]];
            
            NSError *error = nil;
            if (![GBAROM canAddROMToROMDirectory:rom error:&error])
            {
                if ([error code] == NSFileWriteFileExistsError)
                {
                    // Same as above when importing ROM file
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Already Exists", @"")
                                                                        message:NSLocalizedString(@"Only one copy of a game is supported at a time. To use a new version of this game, please delete the previous version and try again.", @"")
                                                                       delegate:nil
                                                              cancelButtonTitle:NSLocalizedString(@"Dismiss", @"") otherButtonTitles:nil];
                        [alert show];
                    });
                    
                    [[NSFileManager defaultManager] removeItemAtPath:rom.filepath error:nil];
                }
                else if ([error code] == NSFileWriteInvalidFileNameError)
                {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Already Exists With This Name", @"")
                                                                        message:NSLocalizedString(@"Please rename either the existing file or the file to be imported and try again.", @"")
                                                                       delegate:nil
                                                              cancelButtonTitle:NSLocalizedString(@"Dismiss", @"") otherButtonTitles:nil];
                        [alert show];
                    });
                    
                    [[NSFileManager defaultManager] removeItemAtPath:rom.filepath error:nil];
                }
                
                continue;
            }
            
            NSString *uniqueName = rom.uniqueName;
            
            if (uniqueName)
            {
                cachedROMs[filename] = uniqueName;
            }
            
            [cachedROMs writeToFile:[self cachedROMsPath] atomically:YES];
            
        }
        
        
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            DLog(@"Finished inital refresh");
            [[GBASyncManager sharedManager] start];
        });
        
    });
    
}
#pragma mark - Filepaths

- (NSString *)skinsDirectory
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    return [documentsDirectory stringByAppendingPathComponent:@"Skins"];
}

- (NSString *)GBASkinsDirectory
{
    NSFileManager *fileManager = [NSFileManager defaultManager]; // Thread-safe as of iOS 5 WOOHOO
    NSString *gbaSkinsDirectory = [[self skinsDirectory] stringByAppendingPathComponent:@"GBA"];
    
    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:gbaSkinsDirectory withIntermediateDirectories:YES attributes:nil error:&error])
    {
        ELog(error);
    }
    
    return gbaSkinsDirectory;
}

- (NSString *)GBCSkinsDirectory
{
    NSFileManager *fileManager = [NSFileManager defaultManager]; // Thread-safe as of iOS 5 WOOHOO
    NSString *gbcSkinsDirectory = [[self skinsDirectory] stringByAppendingPathComponent:@"GBC"];
    
    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:gbcSkinsDirectory withIntermediateDirectories:YES attributes:nil error:&error])
    {
        ELog(error);
    }
    
    return gbcSkinsDirectory;
}

- (NSString *)saveStateDirectoryFovrROM:(GBAROM *)rom
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    
    NSString *saveStateDirectory = [documentsDirectory stringByAppendingPathComponent:@"Save States"];
    
    return [saveStateDirectory stringByAppendingPathComponent:rom.name];
}

- (NSString *)cheatCodeFileForROM:(GBAROM *)rom
{
    NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *cheatCodeDirectory = [documentsDirectory stringByAppendingPathComponent:@"Cheats"];
    
    return nil;
}

- (NSString *)cachedROMsPath
{
    NSString *libraryDirectory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    return [libraryDirectory stringByAppendingPathComponent:@"cachedROMs.plist"];
}

#pragma mark - Controller Skins

- (void)importDefaultSkins
{
    [self importDefaultGBASkin];
    [self importDefaultGBCSkin];
}

- (void)importDefaultGBASkin
{
    NSString *filepath = [[NSBundle mainBundle] pathForResource:@"Default" ofType:@"gbaskin"];
    
    NSString *destinationPath = [[self GBASkinsDirectory] stringByAppendingPathComponent:@"com.GBA4iOS.default"];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath])
    {
        return;
    }
    
    [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
        
    [GBAControllerSkin extractSkinAtPathToSkinsDirectory:filepath];
}

- (void)importDefaultGBCSkin
{
    NSString *filepath = [[NSBundle mainBundle] pathForResource:@"Default" ofType:@"gbcskin"];
    
    NSString *destinationPath = [[self GBCSkinsDirectory] stringByAppendingPathComponent:@"com.GBA4iOS.default"];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath])
    {
        return;
    }
    
    [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
    
    [GBAControllerSkin extractSkinAtPathToSkinsDirectory:filepath];
}

#pragma mark - UIAlertView delegate

- (BOOL)alertViewShouldEnableFirstOtherButton:(UIAlertView *)alertView
{
    NSString *filename = [[alertView textFieldAtIndex:0] text];
    
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.currentDirectory error:nil];
    BOOL fileExists = NO;
    
    for (NSString *item in contents)
    {
        if ([[[item pathExtension] lowercaseString] isEqualToString:@"gba"] || [[[item pathExtension] lowercaseString] isEqualToString:@"gbc"] ||
            [[[item pathExtension] lowercaseString] isEqualToString:@"gb"] || [[[item pathExtension] lowercaseString] isEqualToString:@"zip"])
        {
            NSString *name = [item stringByDeletingPathExtension];
            
            if ([name isEqualToString:filename])
            {
                fileExists = YES;
                break;
            }
        }
    }
    
    if (fileExists)
    {
        alertView.title = NSLocalizedString(@"File Already Exists", @"");
    }
    else
    {
        alertView.title = NSLocalizedString(@"Game Name", @"");
    }
    
    return filename.length > 0 && !fileExists;
}

#pragma mark - Private

- (BOOL)isDownloadingFile:(NSString *)filename
{
    __block BOOL downloadingFile = NO;
    
    NSDictionary *dictionary = [self.currentDownloadsDictionary copy];
    
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, NSString *downloadingFilename, BOOL *stop) {
        if ([downloadingFilename isEqualToString:filename])
        {
            downloadingFile = YES;
            *stop = YES;
        }
    }];
    
    return downloadingFile;
}

- (void)showDownloadProgressView
{
    [self.downloadProgressView setProgress:0.0];
    
    self.downloadProgress.completedUnitCount = 0;
    self.downloadProgress.totalUnitCount = 0;
    
    [UIView animateWithDuration:0.4 animations:^{
        [self.downloadProgressView setAlpha:1.0];
    }];
}

- (void)hideDownloadProgressView
{
    [UIView animateWithDuration:0.4 animations:^{
        [self.downloadProgressView setAlpha:0.0];
    } completion:^(BOOL finished) {
        self.downloadProgress.completedUnitCount = 0;
        self.downloadProgress.totalUnitCount = 0;
        [self.downloadProgressView setProgress:0.0];
    }];
}

- (void)dismissedModalViewController
{
    [self.tableView reloadData]; // Fixes incorrectly-sized cell dividers after changing orientation when a modal view controller is shown
    [self.emulationViewController refreshLayout];
}

- (void)highlightCell:(UITableViewCell *)cell
{
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    UIView *backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
    backgroundView.backgroundColor = GBA4iOS_PURPLE_COLOR;
    backgroundView.alpha = 0.6;
    cell.backgroundView = backgroundView;
}

#pragma mark - UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *filepath = [self filepathForIndexPath:indexPath];
    
    if ([[filepath.pathExtension lowercaseString] isEqualToString:@"zip"])
    {
        return;
    }
    
    GBAROM *rom = [GBAROM romWithContentsOfFile:filepath];
    
    [self startROM:rom];
}

// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete)
    {
        NSString *title = NSLocalizedString(@"Are you sure you want to delete this game and all of its saved data?", nil);
        
        if ([[NSUserDefaults standardUserDefaults] boolForKey:GBASettingsDropboxSyncKey])
        {
            title = [title stringByAppendingFormat:@" Your data in Dropbox will not be affected."];
        }
        
        UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:title
                                                                 delegate:nil
                                                        cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                                   destructiveButtonTitle:NSLocalizedString(@"Delete Game and Saved Data", nil)
                                                        otherButtonTitles:nil];
        
        UIView *presentationView = self.view;
        CGRect rect = [self.tableView rectForRowAtIndexPath:indexPath];
        
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
        {
            presentationView = self.splitViewController.view;
            rect = [presentationView convertRect:rect fromView:self.tableView];
        }
        
        [actionSheet showFromRect:rect inView:presentationView animated:YES selectionHandler:^(UIActionSheet *actionSheet, NSInteger buttonIndex) {
            
            if (buttonIndex == 0)
            {
                [self deleteROMAtIndexPath:indexPath];
            }
        }];
    }
}

#pragma mark - Starting ROM

- (void)startROM:(GBAROM *)rom
{
    [self startROM:rom showSameROMAlertIfNeeded:YES];
}

- (void)startROM:(GBAROM *)rom showSameROMAlertIfNeeded:(BOOL)showSameROMAlertIfNeeded
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:GBASettingsDropboxSyncKey] && [[DBSession sharedSession] isLinked] && ![[GBASyncManager sharedManager] performedInitialSync])
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Syncing with Dropbox", @"")
                                                        message:NSLocalizedString(@"Please wait for the initial sync to be complete, then launch the game. This is to ensure no save data is lost.", @"")
                                                       delegate:nil cancelButtonTitle:NSLocalizedString(@"Dismiss", @"") otherButtonTitles:nil];
        [alert show];
        
        [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
        return;
    }
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:GBASettingsDropboxSyncKey] && [[DBSession sharedSession] isLinked] && [[GBASyncManager sharedManager] isSyncing] && [[GBASyncManager sharedManager] hasPendingDownloadForROM:rom] && ![rom syncingDisabled])
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Syncing with Dropbox", @"")
                                                        message:NSLocalizedString(@"Data for this game is currently being downloaded. To prevent data loss, please wait until the download is complete, then launch the game.", @"")
                                                       delegate:nil
                                              cancelButtonTitle:NSLocalizedString(@"Dismiss", @"")
                                              otherButtonTitles:nil];
        [alert show];
        
        [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
        return;
    }
    
    if ([rom newlyConflicted])
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Data is Conflicted", @"")
                                                        message:NSLocalizedString(@"Data for this game is not in sync with Dropbox, so syncing has been disabled. Please either tap View Details below to resolve the conflict manually, or ignore this message and start the game anyway. If you choose to not resolve the conflict now, you can resolve it later in the Dropbox settings.", @"")
                                                       delegate:nil
                                              cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                              otherButtonTitles:NSLocalizedString(@"View Details", @""), NSLocalizedString(@"Start Anyway", @""), nil];
        [alert showWithSelectionHandler:^(UIAlertView *alertView, NSInteger buttonIndex) {
            if (buttonIndex == 0)
            {
                [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
            }
            else if (buttonIndex == 1)
            {
                GBASyncingDetailViewController *syncingDetailViewController = [[GBASyncingDetailViewController alloc] initWithROM:rom];
                syncingDetailViewController.delegate = self;
                syncingDetailViewController.showDoneButton = YES;
                
                UINavigationController *navigationController = RST_CONTAIN_IN_NAVIGATION_CONTROLLER(syncingDetailViewController);
                
                if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
                {
                    navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
                }
                else
                {
                    [[UIApplication sharedApplication] setStatusBarStyle:[syncingDetailViewController preferredStatusBarStyle] animated:YES];
                }
                
                [self presentViewController:navigationController animated:YES completion:nil];
                
                [rom setNewlyConflicted:NO];
            }
            else if (buttonIndex == 2)
            {
                [rom setNewlyConflicted:NO];
                
                [self startROM:rom];
            }
        }];
        
        return;
    }
        
    void(^showEmulationViewController)(void) = ^(void)
    {
        DLog(@"Unique Name: %@", rom.uniqueName);
        
        NSMutableDictionary *cachedROMs = [NSMutableDictionary dictionaryWithContentsOfFile:[self cachedROMsPath]];
        
        if (cachedROMs[[rom.filepath lastPathComponent]] == nil && rom.uniqueName)
        {
            cachedROMs[[rom.filepath lastPathComponent]] = rom.uniqueName;
            [cachedROMs writeToFile:[self cachedROMsPath] atomically:YES];
        }
                
        [[GBASyncManager sharedManager] setShouldShowSyncingStatus:NO];
        
        
        NSIndexPath *indexPath = [self.tableView indexPathForSelectedRow];
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone)
        {
            UIViewController *presentedViewController = [self.emulationViewController presentedViewController];
            
            if (presentedViewController == self.navigationController)
            {
                // Remove blur ourselves if we've presented a view controller, which would be opaque
                if (self.presentedViewController)
                {
                    [self.emulationViewController removeBlur];
                }
            }
        }
        
        [self.emulationViewController launchGameWithCompletion:^{
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            [self highlightCell:cell];
        }];
    };
    
    if ([self.emulationViewController.rom isEqual:rom] && showSameROMAlertIfNeeded)
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game already in use", @"")
                                                        message:NSLocalizedString(@"Would you like to resume where you left off, or restart the game?", @"")
                                                       delegate:nil
                                              cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                              otherButtonTitles:NSLocalizedString(@"Resume", @""), NSLocalizedString(@"Restart", @""), nil];
        [alert showWithSelectionHandler:^(UIAlertView *alertView, NSInteger buttonIndex) {
            if (buttonIndex == 0)
            {
                [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
            }
            else if (buttonIndex == 1)
            {
                showEmulationViewController();
            }
            else if (buttonIndex == 2)
            {
                self.emulationViewController.rom = rom;
                
                showEmulationViewController();
            }
            
        }];
    }
    else
    {
        if (showSameROMAlertIfNeeded)
        {
            self.emulationViewController.rom = rom;
        }
        
        showEmulationViewController();
    }
}

- (void)userRequestedToPlayROM:(NSNotification *)notification
{
    GBAROM *rom = notification.object;
    
    if ([self.emulationViewController.rom isEqual:rom])
    {
        [self startROM:rom showSameROMAlertIfNeeded:NO];
        return;
    }
    
    if (self.emulationViewController.rom == nil)
    {
        [self startROM:rom];
        return;
    }
    
    NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Would you like to end %@ and start %@? All unsaved data will be lost.", @""), self.emulationViewController.rom.name, rom.name];
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Currently Running", @"")
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                          otherButtonTitles:NSLocalizedString(@"Start Game", @""), nil];
    [alert showWithSelectionHandler:^(UIAlertView *alert, NSInteger buttonIndex) {
        if (buttonIndex == 1)
        {
            [self startROM:rom];
        }
        else
        {
            if (self.presentedViewController == nil)
            {
                [self.emulationViewController resumeEmulation];
            }
        }
    }];
    
    [self.emulationViewController pauseEmulation];
}

- (void)syncingDetailViewControllerDidDismiss:(GBASyncingDetailViewController *)syncingDetailViewController
{
    if (![syncingDetailViewController.rom syncingDisabled] && !([[GBASyncManager sharedManager] isSyncing] && [[GBASyncManager sharedManager] hasPendingDownloadForROM:syncingDetailViewController.rom]))
    {
        [self startROM:syncingDetailViewController.rom];
    }
    else
    {
        [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
    }
}

#pragma mark - Deleting/Renaming/Sharing

- (void)didDetectLongPressGesture:(UILongPressGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer.state != UIGestureRecognizerStateBegan)
    {
        return;
    }
    
    UITableViewCell *cell = (UITableViewCell *)[gestureRecognizer view];
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    
    UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:nil
                                                             delegate:nil
                                                    cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                               destructiveButtonTitle:nil
                                                    otherButtonTitles:NSLocalizedString(@"Rename Game", @""), NSLocalizedString(@"Share Game", @""), nil];
    UIView *presentationView = self.view;
    CGRect rect = [self.tableView rectForRowAtIndexPath:indexPath];
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
    {
        presentationView = self.splitViewController.view;
        rect = [presentationView convertRect:rect fromView:self.tableView];
    }
    
    [actionSheet showFromRect:rect inView:presentationView animated:YES selectionHandler:^(UIActionSheet *actionSheet, NSInteger buttonIndex) {
         if (buttonIndex == 0)
         {
             [self showRenameAlertForROMAtIndexPath:indexPath];
         }
        else if (buttonIndex == 1)
        {
            [self shareROMAtIndexPath:indexPath];
        }
     }];
    
}

- (void)showRenameAlertForROMAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *filepath = [self filepathForIndexPath:indexPath];
    GBAROM *rom = [GBAROM romWithContentsOfFile:filepath];
    
    if ([self.emulationViewController.rom isEqual:rom])
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Cannot Rename Currently Running Game", @"")
                                                        message:NSLocalizedString(@"To rename this game, please quit it so it is no longer running. All unsaved data will be lost.", @"")
                                                       delegate:nil
                                              cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                              otherButtonTitles:NSLocalizedString(@"Quit", @""), nil];
        [alert showWithSelectionHandler:^(UIAlertView *alertView, NSInteger buttonIndex) {
            if (buttonIndex == 1)
            {
                self.emulationViewController.rom = nil;
                [self showRenameAlertForROMAtIndexPath:indexPath];
            }
        }];
        
        return;
    }
    
    NSString *romName = [[filepath lastPathComponent] stringByDeletingPathExtension];
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Rename Game", @"") message:nil delegate:self cancelButtonTitle:NSLocalizedString(@"Cancel", @"") otherButtonTitles:NSLocalizedString(@"Rename", @""), nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    
    UITextField *textField = [alert textFieldAtIndex:0];
    textField.text = romName;
    textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    
    [alert showWithSelectionHandler:^(UIAlertView *alertView, NSInteger buttonIndex) {
        if (buttonIndex == 1)
        {
            UITextField *textField = [alertView textFieldAtIndex:0];
            [self renameROMAtIndexPath:indexPath toName:textField.text];
        }
    }];
}

- (void)deleteROMAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *filepath = [self filepathForIndexPath:indexPath];
    NSString *romName = [[filepath lastPathComponent] stringByDeletingPathExtension];
    
    GBAROM *rom = [GBAROM romWithContentsOfFile:filepath];
    
    if ([self.emulationViewController.rom isEqual:rom])
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Cannot Delete Currently Running Game", @"")
                                                        message:NSLocalizedString(@"To delete this game, please quit it so it is no longer running.", @"")
                                                       delegate:nil
                                              cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                              otherButtonTitles:NSLocalizedString(@"Quit", @""), nil];
        [alert showWithSelectionHandler:^(UIAlertView *alertView, NSInteger buttonIndex) {
            if (buttonIndex == 1)
            {
                self.emulationViewController.rom = nil;
                [self deleteROMAtIndexPath:indexPath];
            }
        }];
        
        return;
    }
    
    NSString *saveFile = [NSString stringWithFormat:@"%@.sav", romName];
    NSString *rtcFile = [NSString stringWithFormat:@"%@.rtc", romName];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    
    NSString *romUniqueName = rom.uniqueName;
    
    if (romUniqueName == nil)
    {
        romUniqueName = @"";
    }
    
    NSString *cheatsParentDirectory = [documentsDirectory stringByAppendingPathComponent:@"Cheats"];
    NSString *cheatsDirectory = [cheatsParentDirectory stringByAppendingPathComponent:romUniqueName];
    
    NSString *saveStateParentDirectory = [documentsDirectory stringByAppendingPathComponent:@"Save States"];
    NSString *saveStateDirectory = [saveStateParentDirectory stringByAppendingString:romUniqueName];
    
    // Handled by deletedFileAtIndexPath
    //[[NSFileManager defaultManager] removeItemAtPath:filepath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[documentsDirectory stringByAppendingPathComponent:saveFile] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[documentsDirectory stringByAppendingPathComponent:rtcFile] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:saveStateDirectory error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:cheatsDirectory error:nil];
    
    NSMutableDictionary *cachedROMs = [NSMutableDictionary dictionaryWithContentsOfFile:[self cachedROMsPath]];
    [cachedROMs removeObjectForKey:romName];
    [cachedROMs writeToFile:[self cachedROMsPath] atomically:YES];
    
    [self deleteFileAtIndexPath:indexPath animated:YES];
}

- (void)renameROMAtIndexPath:(NSIndexPath *)indexPath toName:(NSString *)newName
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    
    NSString *filepath = [self filepathForIndexPath:indexPath];
    NSString *extension = [filepath pathExtension];
    
    NSString *romName = [[filepath lastPathComponent] stringByDeletingPathExtension];
    NSString *newRomFilename = [NSString stringWithFormat:@"%@.%@", newName, extension]; // Includes extension
    
    NSString *saveFile = [NSString stringWithFormat:@"%@.sav", romName];
    NSString *newSaveFile = [NSString stringWithFormat:@"%@.sav", newName];
    
    NSString *rtcFile = [NSString stringWithFormat:@"%@.rtc", romName];
    NSString *newRTCFile = [NSString stringWithFormat:@"%@.rtc", newName];
    
    [[NSFileManager defaultManager] moveItemAtPath:filepath toPath:[documentsDirectory stringByAppendingPathComponent:newRomFilename] error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:[documentsDirectory stringByAppendingPathComponent:saveFile] toPath:[documentsDirectory stringByAppendingPathComponent:newSaveFile] error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:[documentsDirectory stringByAppendingPathComponent:rtcFile] toPath:[documentsDirectory stringByAppendingPathComponent:newRTCFile] error:nil];
    
    NSMutableDictionary *cachedROMs = [NSMutableDictionary dictionaryWithContentsOfFile:[self cachedROMsPath]];
    [cachedROMs setObject:cachedROMs[[filepath lastPathComponent]] forKey:newRomFilename];
    [cachedROMs removeObjectForKey:[filepath lastPathComponent]];
    [cachedROMs writeToFile:[self cachedROMsPath] atomically:YES];
}

- (void)shareROMAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    
    NSString *romFilepath = [self filepathForIndexPath:indexPath];
    
    NSString *romName = [[romFilepath lastPathComponent] stringByDeletingPathExtension];
    NSString *saveFilepath = [documentsDirectory stringByAppendingPathComponent:[romName stringByAppendingString:@".sav"]];
    
    NSURL *romFileURL = [NSURL fileURLWithPath:romFilepath];
    NSURL *saveFileURL = [NSURL fileURLWithPath:saveFilepath];
    
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[romFileURL] applicationActivities:@[[[GBAMailActivity alloc] init]]];
    activityViewController.excludedActivityTypes = @[UIActivityTypeMessage, UIActivityTypeMail]; // Can't install from Messages app, and we use our own Mail activity that supports custom file types
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone)
    {
        [self presentViewController:activityViewController animated:YES completion:NULL];
    }
    else
    {
        CGRect rect = [self.tableView rectForRowAtIndexPath:indexPath];
        rect = [self.splitViewController.view convertRect:rect fromView:self.tableView];
        
        self.activityPopoverController = [[UIPopoverController alloc] initWithContentViewController:activityViewController];
        self.activityPopoverController.delegate = self;
        [self.activityPopoverController presentPopoverFromRect:rect inView:self.splitViewController.view permittedArrowDirections:UIPopoverArrowDirectionLeft animated:YES];
    }
}

#pragma mark - UIPopoverController delegate

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController
{
    self.activityPopoverController = nil;
}

#pragma mark - IBActions

- (IBAction)switchROMTypes:(UISegmentedControl *)segmentedControl
{
    GBAVisibleROMType romType = (GBAVisibleROMType)segmentedControl.selectedSegmentIndex;
    self.romType = romType;
}

- (IBAction)searchForROMs:(UIBarButtonItem *)barButtonItem
{
    NSString *address = @"http://www.google.com/search?q=download+GBA+roms+coolrom&ie=UTF-8&oe=UTF-8&hl=en&client=safari";
    
    if (self.visibleRomType == GBAVisibleROMTypeGBC) // If ALL or GBA is selected, show GBA search results. If GBC, show GBC results
    {
        address = @"http://www.google.com/search?q=download+GBC+roms+coolrom&ie=UTF-8&oe=UTF-8&hl=en&client=safari";
    }
    
    RSTWebViewController *webViewController = [[RSTWebViewController alloc] initWithAddress:address];
    webViewController.excludedActivityTypes = @[UIActivityTypeMessage];
    webViewController.showsDoneButton = YES;
    webViewController.downloadDelegate = self;
    webViewController.delegate = self;
    
    [[UIApplication sharedApplication] setStatusBarStyle:[webViewController preferredStatusBarStyle] animated:YES];
    
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:webViewController];
    [self presentViewController:navigationController animated:YES completion:NULL];
}

- (IBAction)presentSettings:(UIBarButtonItem *)barButtonItem
{
    GBASettingsViewController *settingsViewController = [[GBASettingsViewController alloc] init];
    settingsViewController.delegate = self;
    
    [[UIApplication sharedApplication] setStatusBarStyle:[settingsViewController preferredStatusBarStyle] animated:YES];
    
    UINavigationController *navigationController = RST_CONTAIN_IN_NAVIGATION_CONTROLLER(settingsViewController);
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad)
    {
        navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    [self presentViewController:navigationController animated:YES completion:NULL];
}

#pragma mark - Settings

- (void)settingsViewControllerWillDismiss:(GBASettingsViewController *)settingsViewController
{
    [self dismissedModalViewController];
}

#pragma mark - Getters/Setters

- (void)setRomType:(GBAVisibleROMType)romType
{
    self.romTypeSegmentedControl.selectedSegmentIndex = romType;
    [[NSUserDefaults standardUserDefaults] setInteger:romType forKey:@"romType"];
    
    switch (romType) {
        case GBAVisibleROMTypeAll:
            self.supportedFileExtensions = @[@"gba", @"gbc", @"gb", @"zip"];
            break;
            
        case GBAVisibleROMTypeGBA:
            self.supportedFileExtensions = @[@"gba"];
            break;
            
        case GBAVisibleROMTypeGBC:
            self.supportedFileExtensions = @[@"gb", @"gbc"];
            break;
    }
    
    _visibleRomType = romType;
}

- (void)setTheme:(GBAThemedTableViewControllerTheme)theme
{
    // Navigation controller is different each time, so we need to update theme every time we present this view controller
    /*if (_theme == theme)
    {
        return;
    }*/
    
    _theme = theme;
    
    switch (theme) {
        case GBAThemedTableViewControllerThemeOpaque:
            [self.romTypeSegmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: GBA4iOS_PURPLE_COLOR} forState:UIControlStateNormal];
            [self.romTypeSegmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateSelected];
            break;
            
        case GBAThemedTableViewControllerThemeTranslucent:
            [self.romTypeSegmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
            [self.romTypeSegmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]} forState:UIControlStateSelected];
            break;
    }
    
    [self updateTheme];
    
    self.downloadProgressView.frame = CGRectMake(0,
                                                 CGRectGetHeight(self.navigationController.navigationBar.bounds) - CGRectGetHeight(self.downloadProgressView.bounds),
                                                 CGRectGetWidth(self.navigationController.navigationBar.bounds),
                                                 CGRectGetHeight(self.downloadProgressView.bounds));
    [self.navigationController.navigationBar addSubview:self.downloadProgressView];
}

@end
