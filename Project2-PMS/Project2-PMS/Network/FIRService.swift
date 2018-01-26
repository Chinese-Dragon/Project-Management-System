//
//  FIRService.swift
//  Project2-PMS
//
//  Created by Mark on 1/23/18.
//  Copyright © 2018 RJTCompuquest. All rights reserved.
//

import Foundation
import FirebaseDatabase
import FirebaseStorage
import FirebaseAuth

enum Result<T> {
	case Success(T)
	case Error(String)
}

typealias LoginResultHandler = (User?, Error?) -> ()

class FIRService: NSObject {
    enum FIRServiceError: Error {
        case pathNotFoundInDatabase
        case noUserLoggedIn
        case taskDoesNotExist
        case userDoesNotExist
        case failedToGetUserInfo
    }
    
	static let shareInstance = FIRService()
	
	// Database refences
	private var userRef: DatabaseReference!
	private var databaseRef : DatabaseReference!
	private var storageRef: StorageReference!
	
	private override init() {
		userRef = Database.database().reference().child("Users")
		databaseRef = Database.database().reference()
		storageRef = Storage.storage().reference()
	}
    
	
	// create user profile in DB
    func createUserProfile(ofUser uid: String, name: String?, email: String?, role: String?) {
        let userDict = ["name": name!, "email": email!, "role": role!] as [String: Any]
		databaseRef.child("Users").child(uid).updateChildValues(userDict)
	}
    
    func createOrDeleteTask(task: Task, toCreate: Bool, completion: @escaping (Error?) -> ()) {
        
        guard let userId = CurrentUser.sharedInstance.userId else {
            completion(FIRServiceError.noUserLoggedIn)
            return
        }
        
        // create task and add to "Tasks" table
        let key = databaseRef.child("Tasks").childByAutoId().key
        let taskDict = ["title": task.title!, "description": task.description!, "start date": task.startDate!.timeIntervalSince1970, "due date": task.dueDate!.timeIntervalSince1970, "projectID": task.projectId!, "isCompleted": false] as [String : Any]
        databaseRef.child("Tasks").child(key).updateChildValues(taskDict)
        
        // add the manager who created the task to the task's member list
        assignTaskToUser(taskId: key, userId: userId) { (err) in
            if err != nil {
                print(err!)
            }
            completion(err)
        }
        
    }
    
    func setCompletionStatus(ofTask taskId: String, to status: Bool) {
        databaseRef.child("Tasks").child(taskId).child("isCompleted").setValue(status)
    }
    
    func assignTaskToUser(taskId: String, userId: String, completion: @escaping (Error?) -> ()) {
       // add task to user's tasks list
        databaseRef.child("Users").child(userId).child("tasks").child(taskId).setValue(true)
        
       // add user to task's members list
        databaseRef.child("Tasks").child(taskId).child("members").child(userId).setValue(true)
        completion(nil)
    }
    
    
    func getTaskInfo(ofTask id: String, completion: @escaping (Task?, Error?) -> ()) {
        let ref = databaseRef.child("Tasks").child(id)
        ref.observeSingleEvent(of: DataEventType.value, with: { (snapshot) in
            var taskDict : [String: Any]
            taskDict = snapshot.value as? [String: Any] ?? [:]
            let task = Task(id: id)
            task.title = taskDict["title"] as? String
            task.description = taskDict["description"] as? String
            if let startTimestamp = taskDict["start date"] as? TimeInterval{
                task.startDate = Date(timeIntervalSince1970: startTimestamp)
            }
            if let dueTimestamp = taskDict["due date"] as? TimeInterval {
                task.dueDate = Date(timeIntervalSince1970: dueTimestamp)
            }
            
            task.members = []
            if let members = taskDict["members"] as? [String: Any] {
                let memberIds = Array(members.keys)
                for memberId in memberIds {
                    task.members?.append(memberId)
                }
            }
            
            task.isCompleted = taskDict["isCompleted"] as? Bool
            task.projectId = taskDict["projectID"] as? String
            
            completion(task, nil)
        })
    }
    
    
    func getUserInfo(ofUser id: String, completion: @escaping (Member?, Error?) -> ()) {
        userRef.child(id).observeSingleEvent(of: .value) { (snapshot) in
            if let userDict = snapshot.value as? [String: Any],
                let email = userDict["email"] as? String,
                let name = userDict["name"] as? String,
                let photoUrl = userDict["profile photo"] as? String{
                
                let url = URL(string: photoUrl)
                var image : UIImage? = nil
                if let url = url {
                    image = self.downloadImageWithURL(url: url)
                }
                
                let member = Member(id: id);
                member.email = email
                member.name = name
                member.profileImage = image
                
                completion(member, nil)
            } else {
                completion(nil, FIRServiceError.failedToGetUserInfo)
            }
        }
    }
    
    func downloadImageWithURL(url: URL) -> UIImage! {
        do {
            let data = try NSData(contentsOf: url, options: NSData.ReadingOptions())
            return UIImage(data: data as Data)
        } catch {
            print(error)
        }
        return UIImage()
    }
    
    func getAllTaskIds(ofUser uid: String, completion: @escaping ([String]?, Error?) -> ()) {
        let ref = databaseRef.child("Users").child(uid).child("tasks")
        ref.observeSingleEvent(of: DataEventType.value, with: { (snapshot) in
            var taskDict : [String: Any]
            taskDict = snapshot.value as? [String: Any] ?? [:]
            let tasks : [String] = Array(taskDict.keys)
            completion(tasks, nil)
        })
    }
	
	// Email,Password login
	func loginUser(with email: String, and password: String, completion: @escaping LoginResultHandler) {
		Auth.auth().signIn(withEmail: email, password: password) { (user, error) in
			DispatchQueue.main.async {
				completion(user, error)
			}
		}
	}
	
	// OAuth Login
	func loginUser(with credential: AuthCredential, completion: @escaping LoginResultHandler) {
		Auth.auth().signIn(with: credential) { (user, error) in
			DispatchQueue.main.async {
				completion(user, error)
			}
		}
	}
	
	// Save loggedin user info in Firebase Users table and store into as CurrentUser singleton
	func saveLoggedInUser(_ user: User, completion: @escaping () -> ()) {
		let currentUser = CurrentUser.sharedInstance
		
		userRef.observeSingleEvent(of: .value) { [weak self] (snapshot) in
			if !snapshot.hasChild(user.uid) {
				// If record not exist, create one (only for OAuth)
				self?.userRef.child(user.uid).updateChildValues(
					["name": user.displayName ?? "",
					 "email": user.email!,
					 "profile photo": user.photoURL?.absoluteString ?? ""
					]
				)
				// save oAuth user info to current user
				currentUser.update(id: user.uid,
								   email: user.email!,
								   name: user.displayName!,
								   photoUrl: user.photoURL,
								   role: .none)
				currentUser.save()
				
				DispatchQueue.main.async {
					completion()
				}
			} else {
				// if record exist, fetch it
				self?.fetchCurrentUserInfo(with: user.uid) {
					DispatchQueue.main.async {
						completion()
					}
				}
			}
		}
	}
	
	// Fetch currentuser info from firebase and store in singleton
	func fetchCurrentUserInfo(with id: String, completion: @escaping () -> ()) {
		let currentUser = CurrentUser.sharedInstance
		
		userRef.child(id).observeSingleEvent(of: .value) { (snapshot) in
			if let userDict = snapshot.value as? [String: String],
				let email = userDict["email"],
				let name = userDict["name"] {
				
				// handle situation when user login Oauth but close app in chose role page
				var role: Role!
				if userDict["role"] == nil {
					role = Role.none
				} else {
					role = Role(rawValue: userDict["role"]!)
				}
				
				var photoUrl: URL?
				if let profileUrlStr = userDict["profile photo"] {
					photoUrl = URL(string: profileUrlStr)
				}
				
				currentUser.update(id: id,
								   email: email,
								   name: name,
								   photoUrl: photoUrl,
								   role: role)
				currentUser.save()
				
				DispatchQueue.main.async {
					completion()
				}
			}
		}
	}
}
