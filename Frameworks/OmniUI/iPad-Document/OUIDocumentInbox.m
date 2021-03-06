// Copyright 2010-2015 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OUIDocumentInbox.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import <OmniDocumentStore/ODSFileItem.h>
#import <OmniDocumentStore/ODSLocalDirectoryScope.h>
#import <OmniDocumentStore/ODSStore.h>
#import <OmniDocumentStore/ODSUtilities.h>
#import <OmniFoundation/OFUTI.h>
#import <OmniUIDocument/OUIDocumentAppController.h>
#import <OmniUIDocument/OUIDocumentPicker.h>
#import <OmniUIDocument/OUIErrors.h>
#import <OmniUnzip/OUUnzipArchive.h>
#import <OmniUnzip/OUUnzipEntry.h>


@implementation OUIDocumentInbox

RCS_ID("$Id$");

+ (void)cloneInboxItem:(NSURL *)inboxURL toScope:(ODSScope *)scope completionHandler:(void (^)(ODSFileItem *newFileItem, NSError *errorOrNil))completionHandler;
{
    OBPRECONDITION(scope.hasFinishedInitialScan);
    
    completionHandler = [completionHandler copy];
    
    void (^finishedBlock)(ODSFileItem *newFileItem, NSError *errorOrNil) = ^(ODSFileItem *newFileItem, NSError *errorOrNil) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            
            if (completionHandler) {
                completionHandler(newFileItem, errorOrNil);
            }
        }];
    };
    
    finishedBlock = [finishedBlock copy];
    
    ODSStore *documentStore = scope.documentStore;
    
    [scope performAsynchronousFileAccessUsingBlock:^{
        __autoreleasing NSError *error = nil;
        NSString *uti = OFUTIForFileURLPreferringNative(inboxURL, &error);
        if (!uti) {
            finishedBlock(nil, error);
            return;
        }
        
        BOOL isZip = ODSIsZipFileType(uti);
        OUUnzipArchive *archive = nil;
        if (isZip) {
            archive = [[OUUnzipArchive alloc] initWithPath:[inboxURL path] error:&error];
            if (!archive) {
                finishedBlock(nil, error);
                return;
            }
            
            // this validates that we have a zip with a single file or package
            uti = [self _fileTypeForDocumentInArchive:archive error:&error];
            if (!uti) {
                finishedBlock(nil, error);
                return;
            }
        }
        
        if (![documentStore canViewFileTypeWithIdentifier:uti]) {
            // we're not going to delete the file in the inbox here, because another document store may want to lay claim to this inbox item. Give them a chance to. The calls to cleanupInboxItem: should be daisy-chained from OUIDocumentAppController or it's subclass.
            
            NSLog(@"Delegate says it cannot view file type \"%@\"", uti);
            
            NSString *appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
            OBASSERT(![NSString isEmptyString:appName]);
            
            __autoreleasing NSError *utiShouldNotBeIncludedError = nil;
            NSString *title =  NSLocalizedStringFromTableInBundle(@"Unable to open file.", @"OmniUIDocument", OMNI_BUNDLE, @"error title");
            NSString *description = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"%@ cannot open this type of file.", @"OmniUIDocument", OMNI_BUNDLE, @"error description"), appName];
            OUIDocumentError(&utiShouldNotBeIncludedError, OUICannotMoveItemFromInbox, title, description);
            
            finishedBlock(nil, utiShouldNotBeIncludedError);
            return;
        }
        
        NSURL *itemToMoveURL = nil;
        
        if (isZip) {
            OUUnzipEntry *entry = [[archive entries] objectAtIndex:0];
            NSString *fileName = [[[entry name] pathComponents] objectAtIndex:0];
            NSURL *unzippedFileURL = [archive URLByWritingTemporaryCopyOfTopLevelEntryNamed:fileName error:&error];
            if (!unzippedFileURL) {
                finishedBlock(nil, error);
                
                return;
            }
            // Zip file has been decompressed to unzippedFileURL
            itemToMoveURL = unzippedFileURL;
        }
        else {
            itemToMoveURL = inboxURL;
        }
        
        // This deals with read-only files given to us in the Inbox on iOS. <bug:///60499> (OmniGraphSketcher needs to handle read-only files)
        {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            __autoreleasing NSError *attributesError = nil;
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:[[itemToMoveURL absoluteURL] path] error:&attributesError];
            if (!attributes) {
                // Hopefully non-fatal, but worrisome. We'll log it at least....
                NSLog(@"Error getting attributes of \"%@\": %@", [itemToMoveURL absoluteString], [attributesError toPropertyList]);
            } else {
                NSUInteger mode = [attributes filePosixPermissions];
                if ((mode & S_IWUSR) == 0) {
                    mode |= S_IWUSR;
                    attributesError = nil;
                    if (![fileManager setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:mode] forKey:NSFilePosixPermissions] ofItemAtPath:[[itemToMoveURL absoluteURL] path] error:&attributesError]) {
                        NSLog(@"Error setting attributes of \"%@\": %@", [itemToMoveURL absoluteString], [attributesError toPropertyList]);
                    }
                }
            }
        }

        BOOL shouldConvert = NO;
        OUIDocumentPicker *docPicker = [OUIDocumentAppController controller].documentPicker;
        OBASSERT(docPicker);
        if (docPicker && [docPicker.delegate respondsToSelector:@selector(documentPickerShouldOpenButNotDisplayUTType:)] && [docPicker.delegate respondsToSelector:@selector(documentPicker:saveNewFileIfAppropriateFromFile:completionHandler:)]) {
            BOOL isDirectory = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:[itemToMoveURL path] isDirectory:&isDirectory];
            shouldConvert = [docPicker.delegate documentPickerShouldOpenButNotDisplayUTType:OFUTIForFileExtensionPreferringNative([itemToMoveURL pathExtension], @(isDirectory))];

            if (shouldConvert) { // convert files we claim to view, but do not display in our doc-picker?
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [docPicker.delegate documentPicker:docPicker saveNewFileIfAppropriateFromFile:itemToMoveURL completionHandler:^(BOOL success, ODSFileItem *savedItem, ODSScope *currentScope) {
                        [docPicker.documentStore moveItems:[NSSet setWithObject:savedItem] fromScope:currentScope toScope:scope inFolder:scope.rootFolder completionHandler:^(NSSet *movedFileItems, NSArray *errorsOrNil) {
                            finishedBlock([movedFileItems anyObject], [errorsOrNil firstObject]);
                        }];
                    }];
                }];
                return;
            }
        }

        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [scope addDocumentInFolder:scope.rootFolder fromURL:itemToMoveURL option:ODSStoreAddByCopyingSourceToAvailableDestinationURL completionHandler:finishedBlock];
        }];

    }];
}

+ (BOOL)coordinatedRemoveItemAtURL:(NSURL *)URL error:(NSError **)outError;
{
    __block BOOL success = NO;
    __block NSError *deleteError = nil;
    
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    
    [coordinator coordinateWritingItemAtURL:URL options:NSFileCoordinatorWritingForDeleting error:outError byAccessor:^(NSURL *newURL) {
        __autoreleasing NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:newURL error:&error]) {
            // Deletion of item at URL failed
            NSLog(@"Deletion of inbox item failed: %@", [error toPropertyList]);
            deleteError = error; // strong-ify
            return;
        }
        
        success = YES;
    }];
    
    if (!success && outError)
        *outError = deleteError;
    
    return success;
}

#pragma mark - Private

+ (NSString *)_singleTopLevelEntryNameInArchive:(OUUnzipArchive *)archive directory:(BOOL *)directory error:(NSError **)error;
{
    OBPRECONDITION(archive);
    
    NSString *topLevelEntryName = nil;
    
    if ([[archive entries] count] == 1) {
        // if there's only 1 entry, it should not be a directory
        *directory = NO;
        OUUnzipEntry *entry = [[archive entries] objectAtIndex:0];
        if (![[entry name] hasSuffix:@"/"]) {
            // This zip contains a single file.
            topLevelEntryName = [entry name];
        }
    }
    else if ([[archive entries] count] > 1) {
        // it's a multi-entry zip. All the entries should have the same prefix.
        *directory = YES;
        
        // Filter out unwanted entries (Ex. __MACOSX dir).
        NSArray *filteredEntries = [[archive entries] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
            OUUnzipEntry *entry = (OUUnzipEntry *)evaluatedObject;
            NSString *name = [entry name];
            
            NSRange prefixRange = [name rangeOfString:@"__MACOSX" options:(NSAnchoredSearch | NSCaseInsensitiveSearch)];
            if (prefixRange.location != NSNotFound) {
                return NO;
            }
            
            return YES;
        }]];
        
        // sort entries by length so that the top level directory comes to the top
        NSArray *filteredAndSortedEntries = [filteredEntries sortedArrayUsingComparator:^(id entry1, id entry2) {
            return ([[entry1 name] caseInsensitiveCompare:[entry2 name]]);
        }];
        
        NSString *topLevelFileName = [[filteredAndSortedEntries objectAtIndex:0] name];
        BOOL invalidStructure = [filteredAndSortedEntries anyObjectSatisfiesPredicate:^BOOL(id object) {
            // invalid if any entry name does not start with topLevelFileName.
            OUUnzipEntry *entry = (OUUnzipEntry *)object;
            return ([[entry name] hasPrefix:topLevelFileName] == NO);
        }];
        
        // If the structure if valid, return topLevelFileName
        if (invalidStructure == NO) {
            topLevelEntryName = topLevelFileName;
        }
    }
    
    if (!topLevelEntryName) {
        // Something has gone wrong. Let's fill in Error.
        NSString *title =  NSLocalizedStringFromTableInBundle(@"Invalid Zip Archive", @"OmniUIDocument", OMNI_BUNDLE, @"error title");
        NSString *description = NSLocalizedStringFromTableInBundle(@"The zip archive must contain a single document.", @"OmniUIDocument", OMNI_BUNDLE, @"error description");
        
        OUIDocumentError(error, OUIInvalidZipArchive, title, description);
    }
    
    // By now topLevelEntryName will either have a name or be nil. If it's nil, the error will be filled in.
    return topLevelEntryName;
}

+ (NSString *)_fileTypeForDocumentInArchive:(OUUnzipArchive *)archive error:(NSError **)error; // returns the UTI, or nil if there was an error
{
    OBPRECONDITION(archive);
    
    BOOL isDirectory = NO;
    NSString *topLevelEntryName = [self _singleTopLevelEntryNameInArchive:archive directory:&isDirectory error:error];
    if (!topLevelEntryName)
        return nil;
    
    
    return OFUTIForFileExtensionPreferringNative([topLevelEntryName pathExtension], [NSNumber numberWithBool:isDirectory]);
}

@end
