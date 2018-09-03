//
//  minimalCouch.swift
//  minimalCouch
//
//  Created by Abdol a on 02/10/17.
//  Copyright © 2017 asabdol. All rights reserved.
//

import Foundation
import Alamofire
import SwiftyJSON
import SwiftCloudant

public class MinimalCouch {
    
    private var databaseName: String!
    private var documentID: String!
    private var databaseURL: String!
    private var databaseUsername: String?
    private var databasePassword: String?
    private var client: CouchDBClient!
    
    private var latestRevision:String? = nil
    private var latestSequence:String? = nil
    
    public var database: [String: Any?] = [:]
    public var databaseJSON: JSON = JSON()
    
    public init(databaseName: String, mainDocumentID: String, databaseURL: String, databaseUsername: String?, databasePassword: String?) {
        self.databaseName = databaseName
        self.databaseURL = databaseURL
        self.databaseUsername = databaseUsername
        self.databasePassword = databasePassword
        self.documentID = mainDocumentID
        
        self.connectToDatabase(databaseName: databaseName, databaseURL: databaseURL, databaseUsername: databaseUsername, databasePassword: databasePassword)
        self.read()
    }
    
    internal func connectToDatabase(databaseName: String, databaseURL: String, databaseUsername: String?, databasePassword: String?) {
        let clientURL = NSURL(string:databaseURL)!
        self.client = CouchDBClient(url:clientURL as URL, username:databaseUsername, password:databasePassword)
    }
    
    public func setMainDocument(_ documentID: String){
        self.documentID = documentID
    }
    
    // MARK: READ
    public func read(completionHandler: (() -> ())? = nil) {
        let read = GetDocumentOperation(id: documentID, databaseName: databaseName) { (response, httpInfo, error) in
            if let error = error {
                print("Encountered an error while reading a document. Error:\(error)")
            } else {
                print("Read document: \(String(describing: response))")
                if let _datebase = response {
                    self.database = _datebase
                    self.databaseJSON = JSON(_datebase)
                    if let _latestRevision = _datebase["_rev"] as? String {
                        self.latestRevision = _latestRevision
                        
                        print("Latest revision is \(_latestRevision).")
                        if completionHandler != nil {
                            completionHandler!()
                        }
                    }
                }
            }
        }
        client.add(operation:read)
    }
    
    public func startLongPolling(completionHandler: (() -> ())? = nil) {
        print("Waiting for database changes...")
        
        // Request parameters
        let credentialData = "\(self.databaseUsername):\(self.databasePassword)".data(using: String.Encoding.utf8)!
        let base64Credentials = credentialData.base64EncodedString(options: [])
        let headers = ["Authorization": "Basic \(base64Credentials)"]
        let parameters = { () -> [String : String] in
            if self.latestSequence != nil {
                return ["feed":"longpoll", "since": self.latestSequence!]
            } else {
                return ["feed":"longpoll"]
            }
        }
        
        // Perform polling request
        Alamofire.request(databaseURL + databaseName + "/_changes",
                          method: .get,
                          parameters: parameters(),
                          encoding: URLEncoding.default,
                          headers: self.databaseUsername != nil ? headers : nil)
            .responseJSON { response in // Handle response as JSON
                print("Request: \(String(describing: response.request))")   // original url request
                
                if let _json = response.result.value {
                    let json = JSON(_json)
                    print("JSON: \(json)")
                    
                    if let _latestSequence = json["last_seq"].string {
                        self.latestSequence = _latestSequence
                    }
                    if let _latestRevision = json["results"][0]["changes"][0]["rev"].string {
                        self.latestRevision = _latestRevision
                        self.read() {
                            if completionHandler != nil {
                                DispatchQueue.main.async {
                                    completionHandler!()
                                }
                            }
                        }
                    }
                    self.startLongPolling(completionHandler: completionHandler)
                }
        }
    }
    
    public func update(body: [String: Any?], completionHandler: (() -> ())? = nil) {
        let update = PutDocumentOperation(id: documentID, revision: self.latestRevision, body: body, databaseName: databaseName, completionHandler: { (response, httpInfo, error) in
            if let error = error {
                debugPrint(httpInfo as Any)
                print("Encountered an error while updating a document. Error:\(error)")
            } else {
                print("Update document: \(String(describing: response))")
                if completionHandler != nil {
                    completionHandler!()
                }
            }
            
            // Update local database
            self.database = body
            self.databaseJSON = JSON(self.database)
        })
        client.add(operation: update)
    }
    
    public func update(path: String, value: Any, completionHandler: (() -> ())? = nil) {
        let _keyPath = keyPath(from: path)
        self.database.setValue(value: value, forKeyPath: _keyPath)
        update(body: self.database, completionHandler: completionHandler)
    }
    
    public func delete(path: String, completionHandler: (() -> ())? = nil) {
        let _keyPath = keyPath(from: path)
        self.database.setValue(value: "nil", forKeyPath: _keyPath)
        
        update(body: self.database)
    }
}

extension Dictionary {
    mutating public func setValue(value: Any, forKeyPath keyPath: String) {
        var keys = keyPath.components(separatedBy: ".")
        guard let first = keys.first as? Key else { print("Unable to use string as key on type: \(Key.self)"); return }
        keys.remove(at: 0)
        if keys.isEmpty, let settable = value as? Value {
            self[first] = settable
        } else {
            let rejoined = keys.joined(separator: ".")
            var subdict: [NSObject : AnyObject] = [:]
            if let sub = self[first] as? [NSObject : AnyObject] {
                subdict = sub
            }
            subdict.setValue(value: value, forKeyPath: rejoined)
            if let settable = subdict as? Value {
                self[first] = settable
            } else {
                print("Unable to set value: \(subdict) to dictionary of type: \(type(of: self))")
            }
        }
        
    }
    
    public func valueForKeyPath<T>(keyPath: String) -> T? {
        var keys = keyPath.components(separatedBy: ".")
        guard let first = keys.first as? Key else { print("Unable to use string as key on type: \(Key.self)"); return nil }
        guard let value = self[first] else { return nil }
        keys.remove(at: 0)
        if !keys.isEmpty, let subDict = value as? [NSObject : AnyObject] {
            let rejoined = keys.joined(separator: ".")
            
            return subDict.valueForKeyPath(keyPath: rejoined)
        }
        return value as? T
    }
}

func keyPath(from path: String) -> String {
    let array = path.components(separatedBy: "/")
    var keyPath = ""
    for (index, item) in array.enumerated() {
        let appendix = (index < array.count - 1) ? "." : ""
        keyPath += item + appendix
    }
    return keyPath
}
